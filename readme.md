# Setting Up Xray with Reality and Hysteria2 for TCP/UDP Tunneling on Ubuntu

This guide walks you through setting up Xray (with VLESS + Reality for TCP traffic) and Hysteria2 (for UDP traffic) on the same port 443 on an Ubuntu 24.10 server. This setup is optimized for censorship circumvention in restricted environments like Iran, providing a personal VPN-like tunnel. Xray handles TCP (e.g., browsing), while Hysteria2 adds UDP support (e.g., for gaming like CODM). No domain is required—uses TLS hijacking for Xray and self-signed certs for Hysteria2.

**Note**: This is for personal use. Ensure your server is outside the restricted region (e.g., a VPS). Test thoroughly, as censorship can evolve.

## Prerequisites
- Ubuntu 24.10 server with SSH access (username e.g., `ubuntu`).
- Public IP with port 443 open for TCP and UDP.
- Basic terminal knowledge.
- Run all commands as your user (not root, unless specified).

Update system:
```
sudo apt update && sudo apt upgrade -y
sudo apt install unzip curl openssl -y
```

Open ports:
```
sudo ufw allow ssh
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw enable
sudo ufw status
```

## Step 1: Optimize Kernel Settings
Improve performance for high connections and enable BBR.

Edit `/etc/sysctl.conf`:
```
sudo nano /etc/sysctl.conf
```

Add:
```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 90
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
fs.file-max = 65535000
```

Apply:
```
sudo sysctl -p
```

Verify BBR:
```
sysctl net.ipv4.tcp_congestion_control  # Should show bbr
lsmod | grep bbr  # Should list tcp_bbr
```

## Step 2: Install and Configure Xray with Reality
Xray provides TCP tunneling with Reality for obfuscation.

Create directory:
```
mkdir ~/xray && cd ~/xray
```

Download latest Xray (check https://github.com/XTLS/Xray-core/releases for current version, e.g., v1.8.3 or later):
```
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
unzip Xray-linux-64.zip
chmod +x xray
rm Xray-linux-64.zip
```

Download geo files for routing:
```
wget https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -O geosite.dat
wget https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
wget https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat
```

Generate keys:
```
./xray uuid  # Your UUID (e.g., for "id" in config)
./xray x25519  # PrivateKey and Password (public key)
openssl rand -hex 8  # Short ID (e.g., for shortIds array)
```

Create config.json:
```
nano config.json
```

Paste (replace placeholders like YOUR_UUID, YOUR_PRIVATE_KEY, YOUR_SHORT_ID):
```json
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
      "clients": [{"id": "YOUR_UUID", "flow": "xtls-rprx-vision"}],
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
        "privateKey": "YOUR_PRIVATE_KEY",
        "shortIds": ["YOUR_SHORT_ID", ""]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
```

## Step 3: Install and Configure Hysteria2 for UDP
Hysteria2 adds QUIC/UDP on the same port.

Download latest (check https://github.com/apernet/hysteria/releases for v2.6.5 or later):
```
mkdir ~/hysteria2 && cd ~/hysteria2
wget https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-amd64
chmod +x hysteria-linux-amd64
mv hysteria-linux-amd64 hysteria2
```

Generate self-signed cert (replace YOUR_SERVER_IP):
```
IP="YOUR_SERVER_IP"
openssl genrsa -out server.key 2048
openssl req -new -x509 -days 3650 -key server.key -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" -out server.crt
```

Generate obfuscation password:
```
openssl rand -hex 16  # e.g., "63763e0079806f8cafc3e82672dca514"
```

Create config.yaml (replace YOUR_STRONG_PASSWORD, obfuscation password, paths):
```
nano config.yaml
```

Paste:
```yaml
listen: :443

tls:
  cert: /home/ubuntu/hysteria2/server.crt
  key: /home/ubuntu/hysteria2/server.key

auth:
  type: password
  password: YOUR_STRONG_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true

obfs:
  type: salamander
  salamander:
    password: "your_hex_password_here"  # From openssl rand -hex 16

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
```

## Step 4: Set Up Systemd Services
For both to run on boot.

### Xray Service
```
sudo nano /etc/systemd/system/xray.service
```

Paste (replace username/paths):
```ini
[Unit]
Description=Xray Service (VLESS + Reality)
After=network.target nss-lookup.target

[Service]
User=ubuntu
Group=ubuntu
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/home/ubuntu/xray/xray run -config /home/ubuntu/xray/config.json
Restart=on-failure
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
```

Enable:
```
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl start xray
sudo systemctl status xray
```

### Hysteria2 Service
```
sudo nano /etc/systemd/system/hysteria2.service
```

Paste (replace username/paths):
```ini
[Unit]
Description=Hysteria2 Server (UDP Proxy for Gaming)
After=network.target

[Service]
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/hysteria2
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/home/ubuntu/hysteria2/hysteria2 server -c /home/ubuntu/hysteria2/config.yaml
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

Enable:
```
sudo systemctl daemon-reload
sudo systemctl enable hysteria2
sudo systemctl start hysteria2
sudo systemctl status hysteria2
```

## Step 5: Client Setup (v2rayNG on Android)
Install latest v2rayNG from GitHub.

### For Xray (TCP)
Import VLESS URL:
```
vless://YOUR_UUID@YOUR_SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=YOUR_SHORT_ID&type=tcp&headerType=none#Xray-Reality
```

### For Hysteria2 (UDP)
Add Hysteria2 config:
- Server: YOUR_SERVER_IP
- Port: 443
- Password: YOUR_STRONG_PASSWORD
- SNI: www.microsoft.com
- Allow Insecure: Enabled
- Obfuscation: Salamander with matching password

Switch between configs as needed (Xray for general, Hysteria2 for gaming).

## Troubleshooting
- Logs: `journalctl -u xray -e` or `journalctl -u hysteria2 -e`
- Connection timeout: Rotate dest/SNI (e.g., www.bing.com), shortId, or obfuscation password.
- UDP blocks: Test with `nc -u YOUR_IP 443` from client.
- Update: Download new binaries and restart services.
- If blocked: Add domain via Cloudflare for valid certs (advanced).

This setup is reliable for personal use. Fork and improve on GitHub! If issues, check community repos like XTLS/Xray-core or apernet/hysteria.
