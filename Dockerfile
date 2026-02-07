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
    avahi-utils \
    iproute2 \
    iputils-ping \
    net-tools \
    procps \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI for network discovery
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /config \
    /var/run/restart-trigger

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
