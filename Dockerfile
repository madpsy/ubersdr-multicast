# UberSDR Multicast Relay with Avahi mDNS Bridge
# Forwards multicast traffic from Docker network to host network
# Republishes .local mDNS names for external client resolution

FROM ubuntu:24.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && \
    apt-get install -y \
    smcroute \
    avahi-daemon \
    avahi-utils \
    libavahi-client3 \
    libavahi-common3 \
    dbus \
    iproute2 \
    iputils-ping \
    net-tools \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /config \
    /var/run/restart-trigger \
    /var/run/dbus \
    /etc/avahi

# Configure Avahi daemon for host network publishing
RUN echo '[server]\n\
use-ipv4=yes\n\
use-ipv6=no\n\
ratelimit-interval-usec=1000000\n\
ratelimit-burst=1000\n\
\n\
[wide-area]\n\
enable-wide-area=yes\n\
\n\
[publish]\n\
publish-addresses=yes\n\
publish-hinfo=no\n\
publish-workstation=no\n\
publish-domain=yes\n\
publish-dns-servers=no\n\
publish-resolv-conf-dns-servers=no\n\
\n\
[reflector]\n\
enable-reflector=no\n\
\n\
[rlimits]\n\
rlimit-core=0\n\
rlimit-data=4194304\n\
rlimit-fsize=0\n\
rlimit-nofile=768\n\
rlimit-stack=4194304\n\
rlimit-nproc=3' > /etc/avahi/avahi-daemon.conf

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Health check - verify smcroute is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD pgrep smcroute || exit 1

# Set working directory
WORKDIR /

# Run entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
