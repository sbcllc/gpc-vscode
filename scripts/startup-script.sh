#!/bin/bash
# Startup script for code-server VM
# This script is executed on first boot to install and configure code-server

set -euo pipefail

# Log all output
exec > >(tee -a /var/log/code-server-install.log) 2>&1

echo "=== Starting code-server installation: $(date) ==="

# Update system packages
echo "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install dependencies
echo "Installing dependencies..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    build-essential \
    python3 \
    python3-pip \
    unzip \
    jq

# Install code-server
echo "Installing code-server..."

# Try to get version from instance metadata, fallback to empty (latest)
CODE_SERVER_VERSION=$(curl -s -f "http://metadata.google.internal/computeMetadata/v1/instance/attributes/code-server-version" -H "Metadata-Flavor: Google" 2>/dev/null || echo "")

if [ -n "$CODE_SERVER_VERSION" ]; then
    echo "Installing code-server version: $CODE_SERVER_VERSION"
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --version="$CODE_SERVER_VERSION"
else
    echo "Installing latest code-server version"
    curl -fsSL https://code-server.dev/install.sh | sh
fi

# Create code-server config directory
CODE_SERVER_USER="${CODE_SERVER_USER:-coder}"
CODE_SERVER_HOME="/home/$CODE_SERVER_USER"

# Create user if doesn't exist
if ! id "$CODE_SERVER_USER" &>/dev/null; then
    echo "Creating user: $CODE_SERVER_USER"
    useradd -m -s /bin/bash "$CODE_SERVER_USER"
fi

# Create config directory
mkdir -p "$CODE_SERVER_HOME/.config/code-server"
chown -R "$CODE_SERVER_USER:$CODE_SERVER_USER" "$CODE_SERVER_HOME/.config"

# Configure code-server
# Since IAP handles authentication, we disable password authentication
cat > "$CODE_SERVER_HOME/.config/code-server/config.yaml" << 'EOF'
bind-addr: 127.0.0.1:8080
auth: none
cert: false
EOF

chown "$CODE_SERVER_USER:$CODE_SERVER_USER" "$CODE_SERVER_HOME/.config/code-server/config.yaml"

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/code-server.service << EOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=exec
User=$CODE_SERVER_USER
Group=$CODE_SERVER_USER
WorkingDirectory=$CODE_SERVER_HOME
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080
Restart=on-failure
RestartSec=10

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$CODE_SERVER_HOME
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable code-server
systemctl start code-server

# Wait for code-server to start
echo "Waiting for code-server to start..."
sleep 5

# Check if code-server is running
if systemctl is-active --quiet code-server; then
    echo "code-server is running successfully!"
else
    echo "ERROR: code-server failed to start"
    systemctl status code-server
    exit 1
fi

echo "=== code-server installation completed: $(date) ==="
echo "code-server is listening on 127.0.0.1:8080"
echo "Access via IAP tunnel: gcloud compute start-iap-tunnel <vm-name> 8080 --local-host-port=localhost:8080"
