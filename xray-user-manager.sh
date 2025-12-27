#!/bin/bash

# Xray User Manager - Simple & Clean
# مسیرها رو با تنظیمات خودتون هماهنگ کنید
XRAY_PATH="/home/ubuntu/xray"
CONFIG="$XRAY_PATH/config.json"
BACKUP="$CONFIG.bak"

# چک کردن دسترسی
if [[ $EUID -ne 0 ]]; then
   echo "این اسکریپت باید با sudo اجرا بشه"
   exit 1
fi

# بکاپ گرفتن
cp "$CONFIG" "$BACKUP"

echo "=== مدیریت کاربران Xray (Reality) ==="
echo "1) اضافه کردن کاربر جدید"
echo "2) حذف کاربر (با UUID)"
echo "3) لیست کاربران"
read -p "انتخاب کنید (1-3): " choice

case $choice in
  1)
    read -p "نام کاربر (برای یادداشت، مثلاً ali): " remark
    read -p "UUID دلخواه وارد کنید یا خالی بگذارید تا خودکار تولید بشه: " custom_uuid
    if [ -z "$custom_uuid" ]; then
      custom_uuid=$(uuidgen)
    fi
    read -p "تعداد روز اعتبار (مثلاً 30): " days
    read -p "محدودیت ترافیک به GB (0 = نامحدود): " total_gb

    expiry=$(date -d "+$days days" +%s%3N)  # میلی‌ثانیه برای Xray

    # اضافه کردن به clients
    jq '.inbounds[0].settings.clients += [{
      "id": "'"$custom_uuid"'",
      "flow": "xtls-rprx-vision",
      "email": "'"$remark"'",
      "limitIp": 1,
      "expiryTime": '"$expiry"',
      "totalGB": '"$(($total_gb * 1024 * 1024 * 1024))"'
    }]' "$BACKUP" > "$CONFIG"

    echo "کاربر $remark با UUID $custom_uuid اضافه شد."
    echo "اعتبار: $days روز | ترافیک: $total_gb GB | فقط 1 دستگاه"
    echo
    echo "لینک اتصال (v2rayNG/V2RayN):"
    echo "vless://$custom_uuid@YOUR_SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=YOUR_SHORT_ID&type=tcp#Xray-$remark"
    echo "(YOUR_SERVER_IP و YOUR_PUBLIC_KEY و YOUR_SHORT_ID رو جایگزین کنید)"
    ;;

  2)
    read -p "UUID کاربر برای حذف: " del_uuid
    jq '(.inbounds[0].settings.clients) |= map(select(.id != "'"$del_uuid"'"))' "$BACKUP" > "$CONFIG"
    echo "کاربر با UUID $del_uuid حذف شد."
    ;;

  3)
    jq -r '.inbounds[0].settings.clients[] | "نام: \(.email) | UUID: \(.id) | انقضا: \(.expiryTime) | ترافیک: \(.totalGB)"' "$CONFIG"
    exit 0
    ;;
esac

# اعمال تغییرات
chown ubuntu:ubuntu "$CONFIG"
systemctl restart xray
echo "Xray ری‌استارت شد. تغییرات اعمال شد."
