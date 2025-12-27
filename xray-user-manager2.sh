#!/bin/bash

# Enhanced Xray User Manager - Clean Setup with Traffic Monitoring
# Saves users in JSON, auto UUID generation, expiry check, traffic query via Xray API
# Usage: sudo ./xray-user-manager.sh

set -e

XRAY_PATH="/home/ubuntu/xray"  # Change if your path is different
CONFIG="$XRAY_PATH/config.json"
USERS_FILE="$XRAY_PATH/users.json"
API_ADDR="127.0.0.1:10000"     # Xray API port
INBOUND_TAG="inbound-443"      # Must match "tag" in your config.json inbounds
PUBLIC_KEY="YOUR_PUBLIC_KEY_HERE"   # From xray x25519 → Password line
SHORT_ID="YOUR_SHORT_ID_HERE"
SERVER_IP="YOUR_SERVER_IP_HERE"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Create users.json if it doesn't exist
if [ ! -f "$USERS_FILE" ]; then
    echo "[]" > "$USERS_FILE"
fi

backup_config() {
    cp "$CONFIG" "$CONFIG.bak"
}

load_users() {
    jq . "$USERS_FILE"
}

save_users() {
    echo "$1" | jq . > "$USERS_FILE"
}

add_user() {
    read -p "User remark (e.g., john): " remark
    read -p "Custom UUID (leave blank for auto-generation): " custom_uuid
    if [ -z "$custom_uuid" ]; then
        custom_uuid=$(uuidgen)
    fi
    read -p "Validity in days (e.g., 30): " days
    read -p "Traffic limit in GB (0 = unlimited): " total_gb

    expiry_ms=$(date -d "+$days days" +%s%3N)
    total_bytes=$((total_gb * 1024 * 1024 * 1024))

    # Safe single-line JSON
    user_json=$(printf '{"remark":"%s","uuid":"%s","expiry_ms":%s,"total_bytes":%s}' "$remark" "$custom_uuid" "$expiry_ms" "$total_bytes")

    # Add to users.json
    users=$(load_users | jq ". += [$user_json]")
    save_users "$users"

    # Add to config.json
    backup_config
    jq '.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") .settings.clients += [{
      "id": "'"$custom_uuid"'",
      "flow": "xtls-rprx-vision",
      "email": "'"$remark"'",
      "limitIp": 1,
      "expiryTime": '"$expiry_ms"',
      "totalGB": '"$total_gb"'
    }]' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray

    echo "User $remark added (UUID: $custom_uuid)"
    echo "VLESS Connection Link:"
    echo "vless://$custom_uuid@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$remark"
}

delete_user() {
    read -p "UUID to delete: " del_uuid
    users=$(load_users | jq 'map(select(.uuid != "'"$del_uuid"'"))')
    save_users "$users"

    backup_config
    jq '.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") .settings.clients |= map(select(.id != "'"$del_uuid"'"))' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray
    echo "User with UUID $del_uuid deleted"
}

list_users() {
    echo "=== User List ==="
    users=$(load_users)
    for row in $(echo "$users" | jq -r '.[] | @base64'); do
        _jq() {
            echo "$row" | base64 -d | jq -r "$1"
        }
        remark=$(_jq '.remark')
        uuid=$(_jq '.uuid')
        expiry_ms_raw=$(_jq '.expiry_ms')
        if [ "$expiry_ms_raw" = "null" ] || [ -z "$expiry_ms_raw" ]; then
            expiry_date="Unlimited"
        else
            expiry_date=\( (date -d @" \)((expiry_ms_raw / 1000))" 2>/dev/null || echo "Invalid")
        fi
        total_gb=$((_jq '.total_bytes' / 1024 / 1024 / 1024))

        # Traffic from Xray API
        uplink=$(curl -s "http://$API_ADDR/stat/user/$remark/uplink" | jq -r '.value // 0')
        downlink=$(curl -s "http://$API_ADDR/stat/user/$remark/downlink" | jq -r '.value // 0')
        used_gb=$(((uplink + downlink) / 1024 / 1024 / 1024))

        echo "Remark: $remark | UUID: $uuid | Expiry: $expiry_date | Used: $used_gb / $total_gb GB"
    done
}

check_expiry() {
    now_ms=$(date +%s%3N)
    users=$(load_users | jq 'map(select(.expiry_ms > '"$now_ms"'))')
    save_users "$users"

    backup_config
    jq '.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") .settings.clients |= map(select(.expiryTime > '"$now_ms"'))' "$CONFIG.bak" > "$CONFIG"
    systemctl restart xray
    echo "Expired users removed"
}

# Menu
echo "1) Add User"
echo "2) Delete User"
echo "3) List Users + Traffic"
echo "4) Check & Remove Expired Users"
read -p "Choice: " choice

case $choice in
    1) add_user ;;
    2) delete_user ;;
    3) list_users ;;
    4) check_expiry ;;
    *) echo "Invalid choice" ;;
esac

echo "Done!"
