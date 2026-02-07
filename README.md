# UberSDR Multicast Relay with Avahi mDNS Bridge

A Docker container that bridges multicast traffic and mDNS service discovery between the Docker network and host network for ka9q-radio/UberSDR.

## Features

- **Intelligent Configuration**: Automatically reads UberSDR's `config.yaml` to discover multicast groups
- **mDNS Bridging**: Resolves `.local` hostnames inside Docker and republishes them on the host network
- **Bidirectional Multicast Routing**: Routes multicast traffic in both directions using smcroute
- **Auto-restart**: Monitors restart trigger file to coordinate with UberSDR container restarts
- **Health Monitoring**: Automatically restarts failed services (smcroute, Avahi)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host Network                          │
│  External Clients ←→ [eth0] ←→ Avahi mDNS Publisher        │
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
3. **mDNS Publishing**: Republishes the same hostnames on the host network via `avahi-publish-address`
4. **Multicast Routing**: Configures smcroute to forward multicast traffic bidirectionally
5. **Monitoring**: Watches for process failures and restart triggers

## Usage

### Docker Compose (Recommended)

Add to your `docker-compose.yml`:

```yaml
services:
  multicast-relay:
    build: /home/nathan/repos/ubersdr-multicast
    container_name: multicast-relay
    network_mode: host  # Required for mDNS bridging
    cap_add:
      - NET_ADMIN  # Required for multicast routing
    environment:
      - RELAY_ENABLED=true
      - DOCKER_IFACE=docker0
      - HOST_IFACE=eth0
      - CONFIG_FILE=/config/config.yaml
    volumes:
      - ubersdr-config:/config:ro  # Read-only access to UberSDR config
      - restart-trigger:/var/run/restart-trigger  # Restart coordination
    restart: unless-stopped
    depends_on:
      - radiod
```

### Standalone Docker

```bash
docker build -t ubersdr-multicast /home/nathan/repos/ubersdr-multicast

docker run -d \
  --name multicast-relay \
  --network host \
  --cap-add NET_ADMIN \
  -e RELAY_ENABLED=true \
  -e DOCKER_IFACE=docker0 \
  -e HOST_IFACE=eth0 \
  -v ubersdr-config:/config:ro \
  -v restart-trigger:/var/run/restart-trigger \
  ubersdr-multicast
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_ENABLED` | `true` | Enable/disable the relay (set to `false` to disable) |
| `CONFIG_FILE` | `/config/config.yaml` | Path to UberSDR config file |
| `DOCKER_IFACE` | `docker0` | Docker bridge interface name |
| `HOST_IFACE` | `eth0` | Host network interface name |

## Requirements

- **Network Mode**: Must use `network_mode: host` for mDNS bridging to work
- **Capabilities**: Requires `NET_ADMIN` capability for multicast routing
- **Volumes**: 
  - UberSDR config volume (read-only)
  - Restart trigger volume (shared with UberSDR)

## What Gets Bridged

Based on UberSDR's `config.yaml`:

```yaml
radiod:
  status_group: "hf-status.local:5006"  # Status/control channel
  data_group: "pcm.local:5004"          # Audio data channel
  interface: "lo"
```

The relay will:
1. Resolve `hf-status.local` and `pcm.local` to their multicast IPs (239.x.x.x range)
2. Publish these names on the host network so external clients can resolve them
3. Route multicast traffic for both groups bidirectionally

## Monitoring

### Check Status

```bash
# View logs
docker logs multicast-relay

# Check if smcroute is running
docker exec multicast-relay pgrep smcroute

# Check Avahi publishers
docker exec multicast-relay pgrep avahi-publish

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

### mDNS Names Not Resolving on Host

1. Check if Avahi daemon is running:
   ```bash
   docker exec multicast-relay pgrep avahi-daemon
   ```

2. Check if publishers are running:
   ```bash
   docker exec multicast-relay ps aux | grep avahi-publish
   ```

3. Test resolution from host:
   ```bash
   avahi-resolve-host-name hf-status.local
   ```

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
- `avahi-daemon` - mDNS/DNS-SD daemon
- `avahi-utils` - Avahi command-line tools (avahi-publish-address, avahi-resolve-host-name)
- `dbus` - Required by Avahi daemon
- `iproute2` - Network configuration tools

### Avahi Configuration

The container uses a custom `/etc/avahi/avahi-daemon.conf`:
- IPv4 only (IPv6 disabled)
- Publishes addresses and domains
- No workstation/HINFO publishing
- Reflector disabled (we handle bridging manually)

### Multicast Routing

Uses smcroute with bidirectional rules:
- Docker → Host: Forwards multicast from docker0 to eth0
- Host → Docker: Forwards multicast from eth0 to docker0
- Joins multicast groups on both interfaces

## Integration with ka9q-radio

This container is designed to work with the ka9q-radio ecosystem:

1. **radiod** runs inside Docker and uses Avahi to advertise services
2. **multicast-relay** bridges those services to the host network
3. **External clients** can discover and connect to services as if they were local

The relay is transparent - clients see the same `.local` hostnames and multicast addresses whether they're inside or outside Docker.

## License

See LICENSE file in repository.

## References

- [ka9q-radio](https://github.com/ka9q/ka9q-radio)
- [UberSDR](https://github.com/madpsy/ka9q_ubersdr)
- [smcroute](https://github.com/troglobit/smcroute)
- [Avahi](https://www.avahi.org/)
