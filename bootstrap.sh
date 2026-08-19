#!/bin/bash
set -e

export HOME=/root

# Update package lists and install base tools
apt-get update -y
apt-get install -y curl sudo unzip git

# Install the SSM agent (not preinstalled on Debian's official AMI)
curl -o /tmp/amazon-ssm-agent.deb "https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/latest/debian_arm64/amazon-ssm-agent.deb"
dpkg -i /tmp/amazon-ssm-agent.deb
systemctl enable --now amazon-ssm-agent
rm -f /tmp/amazon-ssm-agent.deb

# Install AWS CLI (needed to fetch the secret at boot)
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# Install code-server using the official install script
curl -fsSL https://code-server.dev/install.sh | sh

# Fetch the code-server password from Secrets Manager
CODE_SERVER_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id devbox/code-server-password \
  --region us-east-2 \
  --query SecretString \
  --output text)

# Create code-server config directory
mkdir -p /root/.config/code-server

# Configure code-server: bind to localhost only, use fetched password
cat > /root/.config/code-server/config.yaml << EOF
bind-addr: 127.0.0.1:8080
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF

# Enable and start code-server as a systemd service
systemctl enable --now code-server@root

# Install cloudflared
curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
dpkg -i /tmp/cloudflared.deb
rm -f /tmp/cloudflared.deb

# Create a systemd service for the quick tunnel
cat > /etc/systemd/system/cloudflared-tunnel.service << 'EOF'
[Unit]
Description=Cloudflare Quick Tunnel for code-server
After=code-server@root.service

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared-tunnel
