#!/bin/bash
# UberSDR Multicast Relay with Avahi mDNS Bridge
# Reads UberSDR config, resolves multicast groups, republishes mDNS, and routes traffic

set -e

# Configuration
CONFIG_FILE="${CONFIG_FILE:-/config/config.yaml}"
RESTART_TRIGGER="/var/run/restart-trigger/restart-multicast-relay"

echo "=========================================="
echo "UberSDR Multicast Relay with Avahi Bridge"
echo "=========================================="
echo "Config file: $CONFIG_FILE"
echo ""

# Wait for config file to exist
echo "Waiting for config file..."
WAIT_COUNT=0
while [ ! -f "$CONFIG_FILE" ]; do
    if [ $WAIT_COUNT -ge 30 ]; then
        echo "ERROR: Config file not found after 30 seconds: $CONFIG_FILE"
        exit 1
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done
echo "Config file found"

# Function to parse YAML config (handles nested keys)
parse_config() {
    local key=$1
    local section=$2
    
    if [ -n "$section" ]; then
        # Parse nested key under a section
        awk -v section="$section" -v key="$key" '
            $0 ~ "^" section ":" { in_section=1; next }
            in_section && $0 ~ "^[^ ]" { in_section=0 }
            in_section && $0 ~ "^[[:space:]]+" key ":" {
                sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
                gsub(/"/, "")
                gsub(/'\''/, "")
                print
                exit
            }
        ' "$CONFIG_FILE"
    else
        # Parse top-level key
        grep "^[[:space:]]*${key}:" "$CONFIG_FILE" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'"
    fi
}

# Parse multicast_relay configuration from config.yaml
echo "Parsing multicast_relay configuration..."
RELAY_ENABLED=$(parse_config "enabled" "multicast_relay")
DOCKER_IFACE=$(parse_config "docker_interface" "multicast_relay")
HOST_IFACE=$(parse_config "host_interface" "multicast_relay")

# Apply defaults if not found in config
RELAY_ENABLED="${RELAY_ENABLED:-true}"
DOCKER_IFACE="${DOCKER_IFACE:-docker0}"
HOST_IFACE="${HOST_IFACE:-eth0}"

echo "Relay enabled: $RELAY_ENABLED"
echo "Docker interface: $DOCKER_IFACE"
echo "Host interface: $HOST_IFACE"
echo ""

# Check if relay is disabled
if [ "$RELAY_ENABLED" != "true" ]; then
    echo "Multicast relay is disabled (enabled=$RELAY_ENABLED)"
    echo "Sleeping indefinitely..."
    sleep infinity
fi

# Parse radiod configuration
echo "Parsing radiod configuration..."
STATUS_GROUP=$(parse_config "status_group" "radiod")
DATA_GROUP=$(parse_config "data_group" "radiod")
RADIOD_IFACE=$(parse_config "interface" "radiod")

if [ -z "$STATUS_GROUP" ] || [ -z "$DATA_GROUP" ]; then
    echo "ERROR: Could not parse status_group or data_group from config"
    echo "STATUS_GROUP: $STATUS_GROUP"
    echo "DATA_GROUP: $DATA_GROUP"
    exit 1
fi

echo "Status group: $STATUS_GROUP"
echo "Data group: $DATA_GROUP"
echo "Radiod interface: $RADIOD_IFACE"

# Extract hostnames and ports
STATUS_HOST=$(echo "$STATUS_GROUP" | cut -d: -f1)
STATUS_PORT=$(echo "$STATUS_GROUP" | cut -d: -f2)
DATA_HOST=$(echo "$DATA_GROUP" | cut -d: -f1)
DATA_PORT=$(echo "$DATA_GROUP" | cut -d: -f2)

echo ""
echo "Extracted configuration:"
echo "  Status: $STATUS_HOST:$STATUS_PORT"
echo "  Data: $DATA_HOST:$DATA_PORT"

# FNV-1 hash function (matches ka9q-radio's fnv1hash)
fnv1hash() {
    local str="$1"
    local hash=2166136261  # FNV-1 offset basis (0x811c9dc5)
    
    for ((i=0; i<${#str}; i++)); do
        local char="${str:$i:1}"
        local byte=$(printf '%d' "'$char")
        hash=$(( (hash * 16777619) & 0xFFFFFFFF ))  # FNV-1 prime (0x01000193)
        hash=$(( hash ^ byte ))
    done
    
    echo $hash
}

# Generate multicast address from hostname using FNV-1 hash
# Matches ka9q-radio's make_maddr() from multicast.c
make_maddr() {
    local hostname="$1"
    
    # Generate hash of hostname
    local hash=$(fnv1hash "$hostname")
    
    # Create address in 239.0.0.0/8 (administratively scoped)
    local addr=$(( (239 << 24) | (hash & 0xffffff) ))
    
    # Avoid 239.0.0.0/24 and 239.128.0.0/24 to prevent MAC address collisions
    if [ $(( addr & 0x007fff00 )) -eq 0 ]; then
        addr=$(( addr | ((addr & 0xff) << 8) ))
    fi
    if [ $(( addr & 0x007fff00 )) -eq 0 ]; then
        addr=$(( addr | 0x00100000 ))
    fi
    
    # Convert to IP address string
    echo "$(( (addr >> 24) & 0xff )).$(( (addr >> 16) & 0xff )).$(( (addr >> 8) & 0xff )).$(( addr & 0xff ))"
}

# Function to resolve multicast address with fallback to hash-based generation
# Matches UberSDR's resolveMulticastAddr() behavior
resolve_mcast() {
    local hostname=$1
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "Resolving $hostname (attempt $attempt/$max_attempts)..."
        
        # Try avahi-resolve-host-name first
        local result=$(avahi-resolve-host-name -4 "$hostname" 2>/dev/null | awk '{print $2}')
        
        if [ -n "$result" ] && [[ "$result" =~ ^239\. ]]; then
            echo "$result"
            return 0
        fi
        
        # If avahi fails, try getent
        result=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}')
        if [ -n "$result" ] && [[ "$result" =~ ^239\. ]]; then
            echo "$result"
            return 0
        fi
        
        sleep 1
        attempt=$((attempt + 1))
    done
    
    # DNS resolution failed - use FNV-1 hash fallback (same as ka9q-radio and UberSDR)
    echo "DNS resolution failed for $hostname, using FNV-1 hash-generated address" >&2
    local generated_ip=$(make_maddr "$hostname")
    echo "$generated_ip"
    return 0
}

# Enable multicast on interfaces
echo ""
echo "Enabling multicast on interfaces..."
if ip link show "$DOCKER_IFACE" >/dev/null 2>&1; then
    ip link set "$DOCKER_IFACE" multicast on || true
    ip link set "$DOCKER_IFACE" allmulticast on || true
    echo "  $DOCKER_IFACE: enabled"
else
    echo "  WARNING: $DOCKER_IFACE not found"
fi

if ip link show "$HOST_IFACE" >/dev/null 2>&1; then
    ip link set "$HOST_IFACE" multicast on || true
    ip link set "$HOST_IFACE" allmulticast on || true
    echo "  $HOST_IFACE: enabled"
else
    echo "  WARNING: $HOST_IFACE not found"
fi

# Start D-Bus for Avahi
echo ""
echo "Starting D-Bus daemon..."
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --fork
sleep 1

# Start Avahi daemon for mDNS publishing on host network
echo "Starting Avahi daemon..."
avahi-daemon --daemonize --no-chroot
sleep 2

# Wait for radiod's Avahi to be ready and resolve addresses
echo ""
echo "Waiting for radiod Avahi services..."
sleep 3

# Resolve multicast addresses
echo ""
echo "Resolving multicast addresses..."
STATUS_IP=$(resolve_mcast "$STATUS_HOST")
DATA_IP=$(resolve_mcast "$DATA_HOST")

if [ -z "$STATUS_IP" ] || [ -z "$DATA_IP" ]; then
    echo "ERROR: Failed to resolve multicast addresses"
    exit 1
fi

echo "Resolved addresses:"
echo "  $STATUS_HOST -> $STATUS_IP"
echo "  $DATA_HOST -> $DATA_IP"

# Republish mDNS names on host network
echo ""
echo "Publishing mDNS names on host network..."
avahi-publish-address "$STATUS_HOST" "$STATUS_IP" &
AVAHI_PID_STATUS=$!
echo "  $STATUS_HOST -> $STATUS_IP (PID: $AVAHI_PID_STATUS)"

avahi-publish-address "$DATA_HOST" "$DATA_IP" &
AVAHI_PID_DATA=$!
echo "  $DATA_HOST -> $DATA_IP (PID: $AVAHI_PID_DATA)"

# Give Avahi time to publish
sleep 2

# Configure smcroute
echo ""
echo "Configuring smcroute for multicast routing..."

# Create smcroute config
cat > /etc/smcroute.conf << EOF
# UberSDR Multicast Relay Configuration
# Auto-generated from $CONFIG_FILE

# Enable multicast routing on interfaces
mgroup from $DOCKER_IFACE group $STATUS_IP
mgroup from $DOCKER_IFACE group $DATA_IP
mgroup from $HOST_IFACE group $STATUS_IP
mgroup from $HOST_IFACE group $DATA_IP

# Bidirectional routing rules
# Docker -> Host
mroute from $DOCKER_IFACE group $STATUS_IP to $HOST_IFACE
mroute from $DOCKER_IFACE group $DATA_IP to $HOST_IFACE

# Host -> Docker
mroute from $HOST_IFACE group $STATUS_IP to $DOCKER_IFACE
mroute from $HOST_IFACE group $DATA_IP to $DOCKER_IFACE
EOF

echo "smcroute configuration:"
cat /etc/smcroute.conf

# Start smcroute
echo ""
echo "Starting smcroute..."
smcroute -d -f /etc/smcroute.conf

# Wait for smcroute to start
sleep 2

# Verify smcroute is running
if ! pgrep smcroute > /dev/null; then
    echo "ERROR: smcroute failed to start"
    exit 1
fi

echo ""
echo "=========================================="
echo "Multicast relay is now active!"
echo "=========================================="
echo "Routing:"
echo "  $STATUS_HOST ($STATUS_IP:$STATUS_PORT) <-> $DOCKER_IFACE <-> $HOST_IFACE"
echo "  $DATA_HOST ($DATA_IP:$DATA_PORT) <-> $DOCKER_IFACE <-> $HOST_IFACE"
echo ""
echo "mDNS publishing:"
echo "  $STATUS_HOST -> $STATUS_IP (on host network)"
echo "  $DATA_HOST -> $DATA_IP (on host network)"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Shutting down multicast relay..."
    
    # Stop Avahi publishers
    if [ -n "$AVAHI_PID_STATUS" ]; then
        kill $AVAHI_PID_STATUS 2>/dev/null || true
    fi
    if [ -n "$AVAHI_PID_DATA" ]; then
        kill $AVAHI_PID_DATA 2>/dev/null || true
    fi
    
    # Stop smcroute
    killall smcroute 2>/dev/null || true
    
    # Stop Avahi daemon
    killall avahi-daemon 2>/dev/null || true
    
    # Stop D-Bus
    killall dbus-daemon 2>/dev/null || true
    
    echo "Cleanup complete"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Background watcher for restart trigger
(
    while true; do
        if [ -f "$RESTART_TRIGGER" ]; then
            echo "Restart trigger detected, restarting..."
            rm -f "$RESTART_TRIGGER"
            cleanup
        fi
        sleep 0.5
    done
) &
WATCHER_PID=$!

# Keep container running and monitor processes
echo "Monitoring processes (PID: $$)..."
echo "Press Ctrl+C to stop"
echo ""

while true; do
    # Check if smcroute is still running
    if ! pgrep smcroute > /dev/null; then
        echo "ERROR: smcroute died, restarting..."
        smcroute -d -f /etc/smcroute.conf
        sleep 2
    fi
    
    # Check if Avahi daemon is still running
    if ! pgrep avahi-daemon > /dev/null; then
        echo "ERROR: avahi-daemon died, restarting..."
        avahi-daemon --daemonize --no-chroot
        sleep 2
        
        # Restart publishers
        kill $AVAHI_PID_STATUS $AVAHI_PID_DATA 2>/dev/null || true
        avahi-publish-address "$STATUS_HOST" "$STATUS_IP" &
        AVAHI_PID_STATUS=$!
        avahi-publish-address "$DATA_HOST" "$DATA_IP" &
        AVAHI_PID_DATA=$!
    fi
    
    sleep 10
done
