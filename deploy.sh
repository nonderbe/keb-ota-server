#!/bin/bash
# deploy.sh — bouw en herstart de OTA server op de Proxmox LXC
# Gebruik: ./deploy.sh [user@host]  (default: root@192.168.176.120)
set -e

HOST="${1:-root@192.168.176.120}"
REMOTE_DIR="/opt/ota-server"

echo "==> Bouwen voor linux/amd64..."
GOOS=linux GOARCH=amd64 go build -o ota-server-linux .

echo "==> Uploaden naar $HOST..."
scp ota-server-linux "$HOST:$REMOTE_DIR/ota-server"
ssh "$HOST" "chown www-data:www-data $REMOTE_DIR/ota-server && systemctl restart ota-server && systemctl status ota-server --no-pager"

rm ota-server-linux
echo "==> Klaar."
