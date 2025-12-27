#!/bin/bash

# Enhanced Xray User Manager - Fully Fixed & Clean
# Usage: sudo ./xray-user-manager.sh

set -e

XRAY_PATH="/home/ubuntu/xray"  # Adjust if needed
CONFIG="$XRAY_PATH/config.json"
USERS_FILE="$XRAY_PATH/users.json"
API_ADDR="127.0.0.1:10000"
INBOUND_TAG="inbound-443"
PUBLIC_KEY="YOUR_PUBLIC_KEY_HERE"
SHORT_ID="YOUR_SHORT_ID_HERE"
SERVER_IP="YOUR_SERVER_IP_HERE"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo"
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    echo "[]" > "$USERS_FILE"
fi

backup_config() {
    cp "$CONFIG" "$CONFIG.bak"
}

add_user() {
    read -p "User remark (e.g., john): " remark
    read -p "Custom UUID (blank for auto): " custom_uuid
    if [ -z "$custom_uuid" ]; then
        custom_uuid=$(uuidgen)
    fi
    read -p "Validity days: " days
    read -p "Traffic limit GB (0=unlimited): " total_gb

    expiry_ms=$(date -d "+$days days" +%s%3N)
    total_bytes=$((total_gb * 1024 * 1024 * 1024))

    user_json=$(printf '{"remark":"%s","uuid":"%s","expiry_ms":%s,"total_bytes":%s}' "$remark" "$custom_uuid" "$expiry_ms" "$total_bytes")

    users=$(jq ". += [$user_json]" "$USERS_FILE")
    echo "$users" > "$USERS_FILE"

    backup_config
    jq '(.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") | .settings.clients) += [{
      "id": "'"$custom_uuid"'",
      "flow": "xtls-rprx-vision",
      "email": "'"$remark"'",
      "limitIp": 1,
      "expiryTime": '"$expiry_ms"',
      "totalGB": '"$total_gb"'
    }]' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray

    echo "User $remark added (UUID: $custom_uuid)"
    echo "Link: vless://$custom_uuid@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$remark"
}

delete_user() {
    read -p "UUID to delete: " del_uuid

    users=$(jq 'map(select(.uuid != "'"$del_uuid"'"))' "$USERS_FILE")
    echo "$users" > "$USERS_FILE"

    backup_config
    jq '(.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") | .settings.clients) |= map(select(.id != "'"$del_uuid"'"))' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray
    echo "User $del_uuid deleted"
}

list_users() {
    echo "=== User List ==="
    for row in $(jq -r '.[] | @base64' "$USERS_FILE"); do
        decoded=$(echo "$row" | base64 -d)
        remark=$(echo "$decoded" | jq -r '.remark')
        uuid=$(echo "$decoded" | jq -r '.uuid')
        expiry_ms=$(echo "$decoded" | jq -r '.expiry_ms')
        total_gb=$(echo "$decoded" | jq -r '.total_bytes' | awk '{print int($1 / 1024 / 1024 / 1024)}')

        if [ "$expiry_ms" = "null" ]; then
            expiry="Unlimited"
        else
            expiry=\( (date -d "@ \)((expiry_ms / 1000))" +"%Y-%m-%d" 2>/dev/null || echo "Invalid")
        fi

        uplink=$(curl -s "http://$API_ADDR/stat/user/$remark/uplink" | jq -r '.value // 0')
        downlink=$(curl -s "http://$API_ADDR/stat/user/$remark/downlink" | jq -r '.value // 0')
        used_gb=$(((uplink + downlink) / 1024 / 1024 / 1024))

        echo "Remark: $remark | UUID: $uuid | Expiry: $expiry | Used: $used_gb / $total_gb GB"
    done
}

check_expiry() {
    now_ms=$(date +%s%3N)
    users=$(jq 'map(select(.expiry_ms > '"$now_ms"'))' "$USERS_FILE")
    echo "$users" > "$USERS_FILE"

    backup_config
    jq '(.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") | .settings.clients) |= map(select(.expiryTime > '"$now_ms"'))' "$CONFIG.bak" > "$CONFIG"
    systemctl restart xray
    echo "Expired users removed"
}

echo "1) Add User  2) Delete User  3) List Users  4) Clean Expired"
read -p "Choice: " choice

case $choice in
    1) add_user ;;
    2) delete_user ;;
    3) list_users ;;
    4) check_expiry ;;
    *) echo "Invalid choice" ;;
esac

echo "Done!"
