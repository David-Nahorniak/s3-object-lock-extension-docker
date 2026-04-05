FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    bash \
    jq \
    curl \
    dcron \
    tzdata \
    python3 \
    py3-pip \
    && pip3 install --no-cache-dir --break-system-packages awscli

# Create app directory
WORKDIR /app

# Copy scripts
COPY file-lock.sh /app/file-lock.sh
COPY test-permissions.sh /app/test-permissions.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/file-lock.sh /app/test-permissions.sh /app/entrypoint.sh

# Create directory for rclone config
RUN mkdir -p /root/.config/rclone

# Create directories for pid files
RUN mkdir -p /var/run

# Use entrypoint script
ENTRYPOINT ["/app/entrypoint.sh"]
