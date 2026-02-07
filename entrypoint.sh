#!/bin/bash
# UberSDR Multicast Relay with Avahi mDNS Bridge
# Reads UberSDR config, resolves multicast groups, republishes mDNS, and routes traffic

set -e

# Configuration
CONFIG_FILE="${CONFIG_FILE:-/config/config.yaml}"
RESTART_TRIGGER="/var/run/restart-trigger/restart-multicast-relay"

# Start restart trigger watcher IMMEDIATELY before anything else
# This ensures it's always running regardless of what happens in the rest of the script
(
    set +e  # Disable exit on error for this subshell
    while true; do
        if [ -f "$RESTART_TRIGGER" ]; then
            echo "[WATCHER] Restart trigger detected, killing main process..."
            rm -f "$RESTART_TRIGGER"
            # Kill the main script process (PID 1) with exit code 1 to trigger Docker restart
            kill -TERM 1
            exit 0
        fi
        sleep 0.5
    done
) &
WATCHER_PID=$!

echo "=========================================="
echo "UberSDR Multicast Relay with Avahi Bridge"
echo "=========================================="
echo "Config file: $CONFIG_FILE"
echo "Restart trigger watcher: PID $WATCHER_PID"
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

# Cleanup function
# Accepts exit code parameter: 0 for normal shutdown, 1 to trigger Docker restart
cleanup() {
    local exit_code=${1:-0}
    echo ""
    echo "Shutting down multicast relay..."

    # Remove iptables TTL rule
    if [ -n "$DOCKER_IFACE" ] && [ -n "$TTL_INCREMENT" ] && command -v iptables &> /dev/null; then
        iptables -t mangle -D PREROUTING -i "$DOCKER_IFACE" -d 239.0.0.0/8 -j TTL --ttl-inc "$TTL_INCREMENT" 2>/dev/null || true
    fi

    # Stop Avahi publishers (using host's Avahi via D-Bus)
    if [ -n "$AVAHI_PID_STATUS" ]; then
        kill $AVAHI_PID_STATUS 2>/dev/null || true
    fi
    if [ -n "$AVAHI_PID_DATA" ]; then
        kill $AVAHI_PID_DATA 2>/dev/null || true
    fi

    # Stop smcroute
    killall smcroute 2>/dev/null || true

    echo "Cleanup complete"
    exit $exit_code
}

trap 'cleanup 1' SIGTERM SIGINT

# Function to discover the host interface with default route
discover_host_interface() {
    echo "Discovering host interface with default route..." >&2

    # Get the interface with the default route
    local iface=$(ip route show default | awk '/default/ {print $5; exit}')

    if [ -z "$iface" ]; then
        echo "WARNING: Could not find default route, falling back to first non-loopback interface" >&2
        iface=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/ {print $2; exit}')
    fi

    if [ -z "$iface" ]; then
        echo "ERROR: Could not discover host interface" >&2
        return 1
    fi

    echo "Discovered host interface: $iface" >&2
    echo "$iface"
}

# Function to discover Docker bridge for ubersdr_sdr-network
discover_docker_bridge() {
    echo "Discovering Docker bridge for ubersdr_sdr-network..." >&2

    # Check if docker command is available
    if ! command -v docker &> /dev/null; then
        echo "WARNING: docker command not available in container, trying fallback methods" >&2

        # Fallback: Look for bridge interfaces matching Docker naming pattern
        local bridge=$(ip link show type bridge | grep -o 'br-[a-f0-9]\{12\}' | head -1)

        if [ -z "$bridge" ]; then
            echo "WARNING: Could not find Docker bridge, falling back to docker0" >&2
            echo "docker0"
            return 0
        fi

        echo "Found Docker bridge via fallback: $bridge" >&2
        echo "$bridge"
        return 0
    fi

    # Try to get the network ID for ubersdr_sdr-network
    local network_id=$(docker network inspect ubersdr_sdr-network -f '{{.Id}}' 2>/dev/null)

    if [ -z "$network_id" ]; then
        echo "WARNING: ubersdr_sdr-network not found, trying alternative names..." >&2

        # Try common variations
        for net_name in "ubersdr-sdr-network" "sdr-network" "ubersdr_default"; do
            network_id=$(docker network inspect "$net_name" -f '{{.Id}}' 2>/dev/null)
            if [ -n "$network_id" ]; then
                echo "Found network as: $net_name" >&2
                break
            fi
        done
    fi

    if [ -z "$network_id" ]; then
        echo "WARNING: Could not find UberSDR network, falling back to docker0" >&2
        echo "docker0"
        return 0
    fi

    # Extract first 12 characters of network ID to form bridge name
    local bridge="br-${network_id:0:12}"

    # Verify the bridge exists
    if ! ip link show "$bridge" &> /dev/null; then
        echo "WARNING: Bridge $bridge does not exist, falling back to docker0" >&2
        echo "docker0"
        return 0
    fi

    echo "Discovered Docker bridge: $bridge (network ID: ${network_id:0:12})" >&2
    echo "$bridge"
}

# Parse multicast_relay configuration from config.yaml
echo "Parsing multicast_relay configuration..."
RELAY_ENABLED=$(parse_config "enabled" "multicast_relay")
ATTEMPT_MDNS=$(parse_config "attempt_mdns_lookup" "multicast_relay")
TTL_INCREMENT=$(parse_config "ttl_increment" "multicast_relay")
HOST_IFACE_CONFIG=$(parse_config "host_interface" "multicast_relay")

# Apply defaults if not found in config
RELAY_ENABLED="${RELAY_ENABLED:-true}"
ATTEMPT_MDNS="${ATTEMPT_MDNS:-false}"
TTL_INCREMENT="${TTL_INCREMENT:-1}"
HOST_IFACE_CONFIG="${HOST_IFACE_CONFIG:-auto}"

echo "Relay enabled: $RELAY_ENABLED"
echo "Attempt mDNS lookup: $ATTEMPT_MDNS"
echo "TTL increment: $TTL_INCREMENT"
echo "Host interface config: $HOST_IFACE_CONFIG"
echo ""

# Dynamically discover network interfaces
echo "=========================================="
echo "Dynamic Interface Discovery"
echo "=========================================="

# Determine host interface
if [ "$HOST_IFACE_CONFIG" = "auto" ]; then
    echo "Auto-discovering host interface..."
    HOST_IFACE=$(discover_host_interface)
    if [ $? -ne 0 ] || [ -z "$HOST_IFACE" ]; then
        echo "ERROR: Failed to discover host interface"
        exit 1
    fi
else
    echo "Using configured host interface: $HOST_IFACE_CONFIG"
    HOST_IFACE="$HOST_IFACE_CONFIG"

    # Verify the interface exists
    if ! ip link show "$HOST_IFACE" >/dev/null 2>&1; then
        echo "ERROR: Configured host interface '$HOST_IFACE' does not exist"
        echo "Available interfaces:"
        ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print "  - " $2}'
        exit 1
    fi
fi

DOCKER_IFACE=$(discover_docker_bridge)
if [ -z "$DOCKER_IFACE" ]; then
    echo "ERROR: Failed to discover Docker bridge interface"
    exit 1
fi

echo ""
echo "Discovered interfaces:"
echo "  Host interface: $HOST_IFACE"
echo "  Docker bridge: $DOCKER_IFACE"
echo "=========================================="
echo ""

# Check if relay is disabled
if [ "$RELAY_ENABLED" != "true" ]; then
    echo "Multicast relay is disabled (enabled=$RELAY_ENABLED)"
    echo "Watching for config changes (restart trigger active)..."
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

    # If mDNS lookup is disabled, go straight to FNV-1 hash
    if [ "$ATTEMPT_MDNS" != "true" ]; then
        echo "Skipping mDNS lookup (attempt_mdns_lookup=false), using FNV-1 hash for $hostname" >&2
        local generated_ip=$(make_maddr "$hostname")
        echo "$generated_ip"
        return 0
    fi

    # Attempt mDNS resolution
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

# Configure iptables to increment TTL for multicast packets
# This is necessary because radiod sends multicast with TTL=1, which prevents forwarding
echo ""
echo "Configuring iptables TTL mangling for multicast forwarding..."
if command -v iptables &> /dev/null; then
    # Remove any existing rules (in case of restart)
    iptables -t mangle -D PREROUTING -i "$DOCKER_IFACE" -d 239.0.0.0/8 -j TTL --ttl-inc "$TTL_INCREMENT" 2>/dev/null || true

    # Add rule to increment TTL for multicast packets from Docker bridge
    if iptables -t mangle -A PREROUTING -i "$DOCKER_IFACE" -d 239.0.0.0/8 -j TTL --ttl-inc "$TTL_INCREMENT"; then
        echo "  TTL increment rule added for $DOCKER_IFACE -> multicast (239.0.0.0/8, +$TTL_INCREMENT)"
    else
        echo "  WARNING: Failed to add iptables TTL rule (multicast forwarding may not work)"
    fi
else
    echo "  WARNING: iptables not available, TTL=1 packets will be dropped during forwarding"
fi

# Verify host's Avahi daemon is accessible via D-Bus
echo ""
echo "Checking host's Avahi daemon..."
if ! avahi-browse -p -t 2>/dev/null | head -1 >/dev/null 2>&1; then
    echo "WARNING: Cannot connect to host's Avahi daemon via D-Bus"
    echo "Make sure:"
    echo "  1. Avahi daemon is running on the host: systemctl status avahi-daemon"
    echo "  2. Host's D-Bus socket is mounted: /var/run/dbus/system_bus_socket"
    echo ""
    echo "Continuing anyway, but mDNS publishing may not work..."
else
    echo "Successfully connected to host's Avahi daemon"
fi

# Resolve multicast addresses
echo ""
echo "Resolving multicast addresses..."
echo "DEBUG: About to resolve STATUS_HOST=$STATUS_HOST"
STATUS_IP=$(resolve_mcast "$STATUS_HOST")
echo "DEBUG: STATUS_IP=$STATUS_IP"

echo "DEBUG: About to resolve DATA_HOST=$DATA_HOST"
DATA_IP=$(resolve_mcast "$DATA_HOST")
echo "DEBUG: DATA_IP=$DATA_IP"

if [ -z "$STATUS_IP" ] || [ -z "$DATA_IP" ]; then
    echo "ERROR: Failed to resolve multicast addresses"
    exit 1
fi

echo "Resolved addresses:"
echo "  $STATUS_HOST -> $STATUS_IP"
echo "  $DATA_HOST -> $DATA_IP"

# Republish mDNS names on host network using host's Avahi daemon
echo ""
echo "Publishing mDNS names on host network (via host's Avahi daemon)..."
avahi-publish-address "$STATUS_HOST" "$STATUS_IP" &
AVAHI_PID_STATUS=$!
echo "  $STATUS_HOST -> $STATUS_IP (PID: $AVAHI_PID_STATUS)"

avahi-publish-address "$DATA_HOST" "$DATA_IP" &
AVAHI_PID_DATA=$!
echo "  $DATA_HOST -> $DATA_IP (PID: $AVAHI_PID_DATA)"

# Give Avahi time to publish
sleep 2

# Configure smcroute
echo "" >&2
echo "Configuring smcroute for multicast routing..." >&2

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

echo "smcroute configuration:" >&2
cat /etc/smcroute.conf >&2

# Start smcroute
echo "" >&2
echo "Starting smcroute..." >&2
smcroute -d -f /etc/smcroute.conf 2>&1

# Wait for smcroute to start
sleep 2

# Verify smcroute is running
if ! pgrep smcroute > /dev/null; then
    echo "ERROR: smcroute failed to start" >&2
    exit 1
fi

echo "" >&2
echo "==========================================" >&2
echo "Multicast relay is now active!" >&2
echo "==========================================" >&2
echo "Routing:" >&2
echo "  $STATUS_HOST ($STATUS_IP:$STATUS_PORT) <-> $DOCKER_IFACE <-> $HOST_IFACE" >&2
echo "  $DATA_HOST ($DATA_IP:$DATA_PORT) <-> $DOCKER_IFACE <-> $HOST_IFACE" >&2
echo "" >&2
echo "mDNS publishing:" >&2
echo "  $STATUS_HOST -> $STATUS_IP (on host network)" >&2
echo "  $DATA_HOST -> $DATA_IP (on host network)" >&2
echo "" >&2

# Keep container running and monitor processes
echo "Monitoring processes (PID: $$)..." >&2
echo "Press Ctrl+C to stop" >&2
echo "" >&2

while true; do
    # Check if smcroute is still running
    if ! pgrep smcroute > /dev/null; then
        echo "ERROR: smcroute died, restarting..."
        smcroute -d -f /etc/smcroute.conf
        sleep 2
    fi

    # Check if Avahi publishers are still running
    if [ -n "$AVAHI_PID_STATUS" ] && ! kill -0 $AVAHI_PID_STATUS 2>/dev/null; then
        echo "ERROR: avahi-publish-address for $STATUS_HOST died, restarting..."
        avahi-publish-address "$STATUS_HOST" "$STATUS_IP" &
        AVAHI_PID_STATUS=$!
    fi

    if [ -n "$AVAHI_PID_DATA" ] && ! kill -0 $AVAHI_PID_DATA 2>/dev/null; then
        echo "ERROR: avahi-publish-address for $DATA_HOST died, restarting..."
        avahi-publish-address "$DATA_HOST" "$DATA_IP" &
        AVAHI_PID_DATA=$!
    fi

    sleep 10
done
