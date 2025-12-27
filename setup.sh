#!/bin/bash

# Xray + Hysteria2 Automatic Setup Script for Ubuntu 24.10
# Optimized for Iran censorship bypass (Reality + Hysteria2 on port 443)
# Author: Grok-assisted guide
# Usage: sudo bash this_script.sh

set -e  # Exit on any error

echo "=================================================="
echo "   Xray (Reality) + Hysteria2 Automatic Installer"
echo "   Ubuntu 24.10 - Personal Use - No Domain Needed"
echo "=================================================="
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

# Ask user for details
read -p "Enter your server username (e.g., ubuntu): " USERNAME
if [ -z "$USERNAME" ]; then
    echo "Username cannot be empty!"
    exit 1
fi

read -p "Enter your server public IP: " SERVER_IP
if [ -z "$SERVER_IP" ]; then
    echo "IP cannot be empty!"
    exit 1
fi

echo
echo "Generating keys..."
UUID=$(curl -s https://www.uuidgenerator.net/api/version4)
PRIVATE_KEY=$(xray x25519 | grep Private | awk '{print $2}')
PUBLIC_KEY=$(xray x25519 | grep Password | awk '{print $2}')  # Newer versions use "Password" as public key
SHORT_ID=$(openssl rand -hex 8)
AUTH_PASS=$(openssl rand -hex 16)
OBFS_PASS=$(openssl rand -hex 16)

echo "Generated UUID: $UUID"
echo "Reality Private Key: $PRIVATE_KEY"
echo "Reality Public Key (for client): $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "Hysteria2 Auth Password: $AUTH_PASS"
echo "Hysteria2 Obfuscation (Salamander) Password: $OBFS_PASS"
echo
read -p "Press Enter to continue installation..."

# Update system and install dependencies
apt update && apt upgrade -y
apt install -y unzip curl openssl ufw

# Open ports
ufw allow ssh
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

# Kernel optimization
cat <<EOF >> /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 90
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
fs.file-max = 65535000
EOF
sysctl -p

# Install Xray
sudo -u $USERNAME mkdir -p /home/$USERNAME/xray
cd /home/$USERNAME/xray

# Download latest Xray (adjust version if needed)
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
unzip Xray-linux-64.zip
chmod +x xray
rm Xray-linux-64.zip

# Geo files
wget https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -O geosite.dat
wget https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
wget https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat

# Xray config
cat <<EOF > config.json
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "outboundTag": "blocked", "domain": ["geosite:category-ads-all", "ext:iran.dat:ads"]},
      {"type": "field", "outboundTag": "direct", "domain": ["ext:iran.dat:ir", "ext:iran.dat:other", "domain:.ir"]},
      {"type": "field", "outboundTag": "direct", "ip": ["geoip:ir", "geoip:private"]}
    ]
  },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.google-analytics.com:443",
        "xver": 0,
        "serverNames": ["www.google-analytics.com", "google-analytics.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID", ""]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF

chown -R $USERNAME:$USERNAME /home/$USERNAME/xray

# Install Hysteria2
sudo -u $USERNAME mkdir -p /home/$USERNAME/hysteria2
cd /home/$USERNAME/hysteria2

wget https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-amd64
chmod +x hysteria-linux-amd64
mv hysteria-linux-amd64 hysteria2

# Self-signed cert
openssl genrsa -out server.key 2048
openssl req -new -x509 -days 3650 -key server.key -subj "/CN=$SERVER_IP" -addext "subjectAltName=IP:$SERVER_IP" -out server.crt

# Hysteria2 config
cat <<EOF > config.yaml
listen: :443

tls:
  cert: /home/$USERNAME/hysteria2/server.crt
  key: /home/$USERNAME/hysteria2/server.key

auth:
  type: password
  password: $AUTH_PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true

obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 15s
  disablePathMTUDiscovery: false

bandwidth:
  up: 200 mbps
  down: 500 mbps

logging:
  level: info
EOF

chown -R $USERNAME:$USERNAME /home/$USERNAME/hysteria2

# Systemd services
# Xray
cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service (VLESS + Reality)
After=network.target nss-lookup.target

[Service]
User=$USERNAME
Group=$USERNAME
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/home/$USERNAME/xray/xray run -config /home/$USERNAME/xray/config.json
Restart=on-failure
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Hysteria2
cat <<EOF > /etc/systemd/system/hysteria2.service
[Unit]
Description=Hysteria2 Server (UDP Gaming Proxy)
After=network.target

[Service]
User=$USERNAME
Group=$USERNAME
WorkingDirectory=/home/$USERNAME/hysteria2
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/home/$USERNAME/hysteria2/hysteria2 server -c /home/$USERNAME/hysteria2/config.yaml
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray hysteria2
systemctl start xray hysteria2

echo
echo "=================================================="
echo "               Installation Complete!"
echo "=================================================="
echo
echo "Xray Status: $(systemctl is-active xray)"
echo "Hysteria2 Status: $(systemctl is-active hysteria2)"
echo
echo "Client Connection Info:"
echo "-----------------------------"
echo "Xray VLESS URL:"
echo "vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#Xray-Reality"
echo
echo "Hysteria2 Settings:"
echo "Server: $SERVER_IP:443"
echo "Password: $AUTH_PASS"
echo "SNI: www.microsoft.com"
echo "Allow Insecure: Yes"
echo "Obfuscation: Salamander"
echo "Obfs Password: $OBFS_PASS"
echo
echo "Logs: journalctl -u xray -f  or  journalctl -u hysteria2 -f"
echo "Enjoy your freedom! 🇮🇷➡️🌍"
