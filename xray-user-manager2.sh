#!/bin/bash

# Enhanced Xray User Manager - Fixed Version (No Empty Config!)
# Usage: sudo ./xray-user-manager.sh

set -e

XRAY_PATH="/home/ubuntu/xray"
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

[ ! -f "$USERS_FILE" ] && echo "[]" > "$USERS_FILE"

backup_config() {
    cp "$CONFIG" "$CONFIG.bak"
    echo "Backup created: $CONFIG.bak"
}

load_users() {
    jq . "$USERS_FILE"
}

save_users() {
    echo "$1" | jq . > "$USERS_FILE"
}

add_user() {
    read -p "User remark (e.g., john): " remark
    read -p "Custom UUID (blank for auto): " custom_uuid
    [ -z "\( custom_uuid" ] && custom_uuid= \)(uuidgen)
    read -p "Validity days: " days
    read -p "Traffic limit GB (0=unlimited): " total_gb

    expiry_ms=$(date -d "+$days days" +%s%3N)
    total_bytes=$((total_gb * 1024 * 1024 * 1024))

    user_json=$(printf '{"remark":"%s","uuid":"%s","expiry_ms":%s,"total_bytes":%s}' "$remark" "$custom_uuid" "$expiry_ms" "$total_bytes")

    users=$(load_users | jq ". += [$user_json]")
    save_users "$users"

    # FIXED: Proper full config update
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
    echo "User $remark added"
    echo "Link: vless://$custom_uuid@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$remark"
}

delete_user() {
    read -p "UUID to delete: " del_uuid

    users=$(load_users | jq 'map(select(.uuid != "'"$del_uuid"'"))')
    save_users "$users"

    # FIXED: Proper full config update
    backup_config
    jq '(.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") | .settings.clients) |= map(select(.id != "'"$del_uuid"'"))' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray
    echo "User $del_uuid deleted"
}

list_users() {
    echo "=== Users ==="
    users=$(load_users)
    for row in $(echo "$users" | jq -r '.[] | @base64'); do
        decoded=$(echo "$row" | base64 -d)
        remark=$(echo "$decoded" | jq -r '.remark')
        uuid=$(echo "$decoded" | jq -r '.uuid')
        expiry_ms_raw=$(echo "$decoded" | jq -r '.expiry_ms')
        total_gb=$(echo "$decoded" | jq -r '.total_bytes' | awk '{print int($1 / 1024 / 1024 / 1024)}')

        if [ "$expiry_ms_raw" = "null" ]; then
            expiry="Unlimited"
        else
            expiry=\( (date -d "@ \)((expiry_ms_raw / 1000))" +"%Y-%m-%d" 2>/dev/null || echo "Invalid")
        fi

        uplink=$(curl -s "http://$API_ADDR/stat/user/$remark/uplink" | jq -r '.value // 0')
        downlink=$(curl -s "http://$API_ADDR/stat/user/$remark/downlink" | jq -r '.value // 0')
        used_gb=$(((uplink + downlink) / 1024 / 1024 / 1024))

        echo "Remark: $remark | UUID: $uuid | Expiry: $expiry | Used: $used_gb / $total_gb GB"
    done
}

check_expiry() {
    now_ms=$(date +%s%3N)
    users=$(load_users | jq 'map(select(.expiry_ms > '"$now_ms"'))')
    save_users "$users"

    backup_config
    jq '(.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") | .settings.clients) |= map(select(.expiryTime > '"$now_ms"'))' "$CONFIG.bak" > "$CONFIG"
    systemctl restart xray
    echo "Expired users cleaned"
}

echo "1) Add User  2) Delete User  3) List  4) Clean Expired"
read -p "Choice: " choice

case $choice in
    1) add_user ;;
    2) delete_user ;;
    3) list_users ;;
    4) check_expiry ;;
    *) echo "Invalid" ;;
esac

echo "Done!"
