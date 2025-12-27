#!/bin/bash

# Enhanced Xray User Manager - Clean Setup with Traffic Monitoring
# Saves users in JSON, auto UUID, expiry check, traffic query via Xray API
# Assumptions: Xray config has stats/API enabled (see guide below)
# Usage: sudo ./xray-user-manager.sh

set -e

XRAY_PATH="/home/ubuntu/xray"  # Adjust if needed
CONFIG="$XRAY_PATH/config.json"
USERS_FILE="$XRAY_PATH/users.json"
API_ADDR="127.0.0.1:10000"  # Xray API port
INBOUND_TAG="inbound-443"   # Add "tag": "inbound-443" to your inbounds in config.json
PUBLIC_KEY="YOUR_PUBLIC_KEY_HERE"  # From xray x25519 Password
SHORT_ID="YOUR_SHORT_ID_HERE"
SERVER_IP="YOUR_SERVER_IP_HERE"

# Check root
if [[ $EUID -ne 0 ]]; then
   echo "Run as sudo"
   exit 1
fi

# Create users.json if not exists
if [ ! -f "$USERS_FILE" ]; then
    echo "[]" > "$USERS_FILE"
fi

# Functions
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
    read -p "User remark (e.g., ali): " remark
    read -p "Custom UUID (leave blank for auto): " custom_uuid
    if [ -z "$custom_uuid" ]; then
        custom_uuid=$(uuidgen)
    fi
    read -p "Days until expiry (e.g., 30): " days
    read -p "Total GB limit (0 = unlimited): " total_gb

    expiry_ms=$(date -d "+$days days" +%s%3N)
    user_json='{
      "remark": "'"$remark"'",
      "uuid": "'"$custom_uuid"'",
      "expiry_ms": '"$expiry_ms"',
      "total_bytes": '"$(($total_gb * 1024 * 1024 * 1024))"'
    }'

    # Add to users.json
    users=$(load_users | jq '. += ['"$user_json"']')
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

    echo "Added user $remark (UUID: $custom_uuid)"
    echo "VLESS Link: vless://$custom_uuid@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google-analytics.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$remark"
}

delete_user() {
    read -p "UUID to delete: " del_uuid
    users=$(load_users | jq 'map(select(.uuid != "'"$del_uuid"'"))')
    save_users "$users"

    backup_config
    jq '.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") .settings.clients |= map(select(.id != "'"$del_uuid"'"))' "$CONFIG.bak" > "$CONFIG"

    systemctl restart xray
    echo "Deleted UUID $del_uuid"
}

list_users() {
    echo "Users List (with Traffic/Expiry):"
    users=$(load_users)
    for row in $(echo "$users" | jq -r '.[] | @base64'); do
        _jq() { echo \( {row} | base64 --decode | jq -r \){1}; }
        remark=$(_jq '.remark')
        uuid=$(_jq '.uuid')
        expiry_date=\( (date -d @ \)((${_jq '.expiry_ms'} / 1000)))
        total_limit=\( (( \){_jq '.total_bytes'} / 1024 / 1024 / 1024))  # GB

        # Query traffic (uplink + downlink)
        uplink=$(curl -s "http://$API_ADDR/stats/user>>>$remark>>>uplink" | jq -r '.value // 0')
        downlink=$(curl -s "http://$API_ADDR/stats/user>>>$remark>>>downlink" | jq -r '.value // 0')
        used_gb=$(( ($uplink + $downlink) / 1024 / 1024 / 1024 ))

        echo "Remark: $remark | UUID: $uuid | Expiry: $expiry_date | Used: $used_gb GB / $total_limit GB"
    done
}

check_expiry() {
    now_ms=$(date +%s%3N)
    users=$(load_users | jq 'map(select(.expiry_ms > '"$now_ms"'))')
    save_users "$users"

    backup_config
    jq '.inbounds[] | select(.tag == "'"$INBOUND_TAG"'") .settings.clients |= map(select(.expiryTime > '"$now_ms"'))' "$CONFIG.bak" > "$CONFIG"
    systemctl restart xray
    echo "Expired users removed."
}

# Menu
echo "1) Add User"
echo "2) Delete User"
echo "3) List Users with Traffic"
echo "4) Check & Remove Expired"
read -p "Choice: " choice

case $choice in
  1) add_user ;;
  2) delete_user ;;
  3) list_users ;;
  4) check_expiry ;;
esac

echo "Done! Run 'journalctl -u xray -e' for logs."
