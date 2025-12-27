# راه‌اندازی Xray با Reality و Hysteria2 برای تونلینگ TCP/UDP در اوبونتو

این راهنما شما را قدم به قدم برای راه‌اندازی **Xray** (با پروتکل VLESS + Reality برای ترافیک TCP) و **Hysteria2** (برای ترافیک UDP) روی یک سرور اوبونتو ۲۴.۱۰ همراهی می‌کند. این تنظیمات برای دور زدن سانسور در محیط‌های محدود مانند ایران بهینه شده و یک تونل شخصی شبیه VPN فراهم می‌کند. Xray ترافیک TCP (مثل مرور وب) را مدیریت می‌کند و Hysteria2 پشتیبانی از UDP (مثل بازی‌هایی نظیر CODM) را اضافه می‌کند. **نیازی به دامنه نیست** — از TLS hijacking برای Xray و گواهی خود-امضا برای Hysteria2 استفاده می‌شود.

**توجه**: این راهنما برای استفاده شخصی است. سرور شما باید خارج از منطقه محدود باشد (مثلاً VPS). همیشه تست کنید، زیرا روش‌های سانسور ممکن است تغییر کنند.

## پیش‌نیازها
- سرور اوبونتو ۲۴.۱۰ با دسترسی SSH (نام کاربری مثلاً `ubuntu`).
- آی‌پی عمومی با پورت ۴۴۳ باز برای TCP و UDP.
- آشنایی اولیه با ترمینال.
- تمام دستورات را با کاربر عادی اجرا کنید (مگر جایی که `sudo` ذکر شده).

به‌روزرسانی سیستم:
```
sudo apt update && sudo apt upgrade -y
sudo apt install unzip curl openssl -y
```

باز کردن پورت‌ها:
```
sudo ufw allow ssh
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw enable
sudo ufw status
```

## مرحله ۱: بهینه‌سازی تنظیمات کرنل
بهبود عملکرد برای اتصالات زیاد و فعال‌سازی BBR.

ویرایش `/etc/sysctl.conf`:
```
sudo nano /etc/sysctl.conf
```

اضافه کنید:
```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 90
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
fs.file-max = 65535000
```

اعمال تغییرات:
```
sudo sysctl -p
```

بررسی BBR:
```
sysctl net.ipv4.tcp_congestion_control  # باید bbr نمایش دهد
lsmod | grep bbr  # باید tcp_bbr را نشان دهد
```

## مرحله ۲: نصب و تنظیم Xray با Reality
Xray تونل TCP با Reality برای مخفی‌سازی ارائه می‌دهد.

ساخت پوشه:
```
mkdir ~/xray && cd ~/xray
```

دانلود آخرین نسخه Xray (نسخه فعلی را از https://github.com/XTLS/Xray-core/releases بررسی کنید):
```
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
unzip Xray-linux-64.zip
chmod +x xray
rm Xray-linux-64.zip
```

دانلود فایل‌های geo برای روتینگ:
```
wget https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -O geosite.dat
wget https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
wget https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat
```

تولید کلیدها:
```
./xray uuid  # UUID شما
./xray x25519  # PrivateKey و Password (کلید عمومی)
openssl rand -hex 8  # Short ID
```

ساخت config.json:
```
nano config.json
```

محتویات زیر را بچسبانید (جایگزین‌های YOUR_UUID، YOUR_PRIVATE_KEY، YOUR_SHORT_ID را پر کنید):
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

## مرحله ۳: نصب و تنظیم Hysteria2 برای UDP
Hysteria2 پشتیبانی QUIC/UDP را روی همان پورت اضافه می‌کند.

دانلود آخرین نسخه (نسخه را از https://github.com/apernet/hysteria/releases بررسی کنید):
```
mkdir ~/hysteria2 && cd ~/hysteria2
wget https://github.com/apernet/hysteria/releases/download/app/v2.6.5/hysteria-linux-amd64
chmod +x hysteria-linux-amd64
mv hysteria-linux-amd64 hysteria2
```

تولید گواهی خود-امضا (YOUR_SERVER_IP را جایگزین کنید):
```
IP="YOUR_SERVER_IP"
openssl genrsa -out server.key 2048
openssl req -new -x509 -days 3650 -key server.key -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" -out server.crt
```

تولید رمز obfuscation:
```
openssl rand -hex 16  # مثلاً "63763e0079806f8cafc3e82672dca514"
```

ساخت config.yaml (YOUR_STRONG_PASSWORD و رمز obfuscation و مسیرها را جایگزین کنید):
```
nano config.yaml
```

محتویات:
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
    password: "your_hex_password_here"  # خروجی openssl rand -hex 16

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

## مرحله ۴: راه‌اندازی سرویس‌های Systemd
تا هر دو سرویس هنگام بوت اجرا شوند.

### سرویس Xray
```
sudo nano /etc/systemd/system/xray.service
```

محتویات (نام کاربری و مسیرها را تنظیم کنید):
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

فعال‌سازی:
```
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl start xray
sudo systemctl status xray
```

### سرویس Hysteria2
```
sudo nano /etc/systemd/system/hysteria2.service
```

محتویات (نام کاربری و مسیرها را تنظیم کنید):
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

فعال‌سازی:
```
sudo systemctl daemon-reload
sudo systemctl enable hysteria2
sudo systemctl start hysteria2
sudo systemctl status hysteria2
```

## مرحله ۵: تنظیم کلاینت (v2rayNG در اندروید)
آخرین نسخه v2rayNG را از GitHub نصب کنید.

### برای Xray (TCP)
لینک VLESS را وارد کنید:
```
vless://YOUR_UUID@YOUR_SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=YOUR_SHORT_ID&type=tcp&headerType=none#Xray-Reality
```

### برای Hysteria2 (UDP)
تنظیم Hysteria2:
- سرور: YOUR_SERVER_IP
- پورت: ۴۴۳
- رمز: YOUR_STRONG_PASSWORD
- SNI: www.microsoft.com
- Allow Insecure: فعال
- Obfuscation: Salamander با همان رمز

بین دو کانفیگ جابه‌جا شوید (Xray برای مرور عمومی، Hysteria2 برای بازی).

## عیب‌یابی
- لاگ‌ها: `journalctl -u xray -e` یا `journalctl -u hysteria2 -e`
- قطع اتصال: dest/SNI را تغییر دهید (مثل www.bing.com)، shortId یا رمز obfuscation را عوض کنید.
- مسدود شدن UDP: با `nc -u YOUR_IP 443` از کلاینت تست کنید.
- به‌روزرسانی: باینری جدید دانلود و سرویس‌ها را ری‌استارت کنید.
- در صورت مسدود شدن: دامنه از طریق Cloudflare اضافه کنید (پیشرفته).

این تنظیمات برای استفاده شخصی بسیار قابل اعتماد است. می‌توانید در GitHub فورک کنید و بهبود دهید! در صورت مشکل، مخازن XTLS/Xray-core یا apernet/hysteria را بررسی کنید.
