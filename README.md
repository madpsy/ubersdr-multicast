# UberSDR Multicast Relay

A Docker container that bridges multicast traffic between the Docker network and host network for ka9q-radio/UberSDR.

## Features

- **Intelligent Configuration**: Automatically reads UberSDR's `config.yaml` to discover multicast groups
- **mDNS Resolution**: Resolves `.local` hostnames to multicast IPs using Avahi
- **Bidirectional Multicast Routing**: Routes multicast traffic in both directions using smcroute
- **Auto-restart**: Monitors restart trigger file to coordinate with UberSDR container restarts
- **Health Monitoring**: Automatically restarts failed services (smcroute)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host Network                          │
│  External Clients ←→ [eth0]                                 │
└────────────────────────────┬────────────────────────────────┘
                             │
                    Multicast Routing
                      (smcroute)
                             │
┌────────────────────────────┴────────────────────────────────┐
│                     Docker Network (docker0)                 │
│  radiod (Avahi) ←→ UberSDR ←→ Multicast Groups             │
│  - hf-status.local (239.x.x.x:5006)                         │
│  - pcm.local (239.y.y.y:5004)                               │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Config Parsing**: Reads `/config/config.yaml` to extract `status_group` and `data_group`
2. **mDNS Resolution**: Uses Avahi to resolve `.local` hostnames to multicast IPs inside Docker
3. **Multicast Routing**: Configures smcroute to forward multicast traffic bidirectionally
4. **Monitoring**: Watches for process failures and restart triggers

## Usage

### Docker Compose (Recommended)

Add to your `docker-compose.yml`:

```yaml
services:
  multicast-relay:
    build: /home/nathan/repos/ubersdr-multicast
    container_name: multicast-relay
    network_mode: host  # Required for multicast routing
    cap_add:
      - NET_ADMIN  # Required for multicast routing
    environment:
      - RELAY_ENABLED=true
      - CONFIG_FILE=/config/config.yaml
    volumes:
      - ubersdr-config:/config:ro  # Read-only access to UberSDR config
      - restart-trigger:/var/run/restart-trigger  # Restart coordination
      - /var/run/docker.sock:/var/run/docker.sock:ro  # For network discovery
    restart: unless-stopped
    depends_on:
      - radiod
```

**Note**: Network interfaces are now automatically discovered:
- **Host interface**: Detected via default route
- **Docker bridge**: Discovered from `ubersdr_sdr-network` (or fallback to `docker0`)

### Standalone Docker

```bash
docker build -t ubersdr-multicast /home/nathan/repos/ubersdr-multicast

docker run -d \
  --name multicast-relay \
  --network host \
  --cap-add NET_ADMIN \
  -e RELAY_ENABLED=true \
  -e CONFIG_FILE=/config/config.yaml \
  -v ubersdr-config:/config:ro \
  -v restart-trigger:/var/run/restart-trigger \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  ubersdr-multicast
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_ENABLED` | `true` | Enable/disable the relay (set to `false` to disable) |
| `CONFIG_FILE` | `/config/config.yaml` | Path to UberSDR config file |

## Requirements

- **Network Mode**: Must use `network_mode: host` for multicast routing to work
- **Capabilities**: Requires `NET_ADMIN` capability for multicast routing
- **Volumes**:
  - UberSDR config volume (read-only)
  - Restart trigger volume (shared with UberSDR)
  - Docker socket (read-only, for automatic network discovery)

## Network Discovery

The container automatically discovers network interfaces:

1. **Host Interface**: Finds the interface with the default route using `ip route show default`
   - Fallback: First non-loopback interface if no default route exists

2. **Docker Bridge**: Discovers the bridge for `ubersdr_sdr-network` by:
   - Querying Docker API via mounted socket
   - Extracting network ID and deriving bridge name (`br-<network-id-prefix>`)
   - Fallback: Tries alternative network names (`ubersdr-sdr-network`, `sdr-network`, `ubersdr_default`)
   - Final fallback: Uses `docker0` if network not found

This eliminates the need to manually configure interface names in your environment variables.

## Configuration

Based on UberSDR's `config.yaml`:

```yaml
radiod:
  status_group: "hf-status.local:5006"  # Status/control channel
  data_group: "pcm.local:5004"          # Audio data channel
  interface: "lo"

multicast_relay:
  enabled: true                # Enable/disable relay (default: true)
  attempt_mdns_lookup: false   # Try mDNS resolution before hash (default: false)
  ttl_increment: 1             # Increment TTL for forwarded packets (default: 1)
  host_interface: auto         # Host network interface (default: auto, or specify 'eth0', 'eno1', etc.)
```

The relay will:
1. Resolve `hf-status.local` and `pcm.local` to their multicast IPs (239.x.x.x range)
2. Route multicast traffic for both groups bidirectionally
3. Increment TTL of multicast packets to allow forwarding across network boundaries

### TTL Configuration

The `ttl_increment` setting solves a common issue where multicast sources (like radiod) send packets with TTL=1, which prevents them from being forwarded across network boundaries. The relay uses iptables to increment the TTL before forwarding:

- **Default**: `1` (increments TTL from 1 to 2, allowing one forwarding hop)
- **Range**: `1-255` (higher values allow more hops, but typically only 1 is needed)
- **When to adjust**: If you have multiple network hops between Docker and your clients, increase this value

### Host Interface Configuration

The `host_interface` setting allows you to specify which network interface to use for the host side of the multicast relay:

- **Default**: `auto` (automatically discovers the interface with the default route)
- **Manual**: Specify an interface name like `eth0`, `eno1`, `wlan0`, etc.
- **When to specify**: If you have multiple network interfaces and want to control which one is used for multicast forwarding
- **Validation**: The script will verify the interface exists and show available interfaces if the specified one is not found

## Monitoring

### Check Status

```bash
# View logs
docker logs multicast-relay

# Check if smcroute is running
docker exec multicast-relay pgrep smcroute

# View smcroute configuration
docker exec multicast-relay cat /etc/smcroute.conf

# View multicast routes
docker exec multicast-relay smcroutectl show
```

### Health Check

The container includes a health check that monitors smcroute:

```bash
docker inspect --format='{{.State.Health.Status}}' multicast-relay
```

## Restart Coordination

The container watches for `/var/run/restart-trigger/restart-multicast-relay`. When this file is created, the container will gracefully restart all services.

To trigger a restart from UberSDR or another container:

```bash
touch /var/run/restart-trigger/restart-multicast-relay
```

## Troubleshooting

### Multicast Traffic Not Flowing

1. Check smcroute status:
   ```bash
   docker exec multicast-relay smcroutectl show
   ```

2. Verify interfaces have multicast enabled:
   ```bash
   ip link show docker0 | grep MULTICAST
   ip link show eth0 | grep MULTICAST
   ```

3. Check multicast group memberships:
   ```bash
   netstat -g
   ```

### Container Won't Start

1. Verify `network_mode: host` is set
2. Ensure `NET_ADMIN` capability is granted
3. Check if config file exists and is readable
4. Review logs: `docker logs multicast-relay`

## Technical Details

### Packages Installed

- `smcroute` - Multicast routing daemon
- `iproute2` - Network configuration tools
- `iptables` - Packet filtering and TTL manipulation

### Multicast Routing

Uses smcroute with bidirectional rules:
- Docker → Host: Forwards multicast from docker0 to eth0
- Host → Docker: Forwards multicast from eth0 to docker0
- Joins multicast groups on both interfaces

### TTL Handling

The container uses iptables mangle table to increment TTL for multicast packets:
- Rule: `iptables -t mangle -A PREROUTING -i <docker-bridge> -d 239.0.0.0/8 -j TTL --ttl-inc <value>`
- Applied before routing decisions to ensure packets survive the forwarding hop
- Configurable via `multicast_relay.ttl_increment` in config.yaml
- Automatically cleaned up on container shutdown

## Integration with ka9q-radio

This container is designed to work with the ka9q-radio ecosystem:

1. **radiod** runs inside Docker and uses Avahi to advertise services
2. **multicast-relay** bridges multicast traffic to the host network
3. **External clients** can connect to services using the multicast addresses

## License

See LICENSE file in repository.

## References

- [ka9q-radio](https://github.com/ka9q/ka9q-radio)
- [UberSDR](https://github.com/madpsy/ka9q_ubersdr)
- [smcroute](https://github.com/troglobit/smcroute)
- [Avahi](https://www.avahi.org/)
