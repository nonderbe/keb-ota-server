#!/bin/bash
# test-mock.sh — release a mock firmware binary to the OTA server for end-to-end testing.
#
# The mock binary is a copy of an existing firmware file (or any .bin you provide).
# It tests the full signing → upload → manifest → device-download flow without
# requiring a full PlatformIO build.
#
# Usage: ./test-mock.sh [path/to/firmware.bin]
#   (default: uses firmware-v0.1.3.bin from ../kill-energy-bill/ if present)
#
# Required env:
#   ADMIN_TOKEN            — OTA server admin token
#
# Optional env:
#   FIRMWARE_SIGNING_KEY   — path to private key (default: ./firmware_signing_private.pem)
#   OTA_HOST               — SSH host                (default: root@192.168.176.120)
#   MOCK_VERSION           — version string to release (default: 99.0.0)
#   MOCK_CHANNEL           — channel to release to    (default: stable)
set -euo pipefail

ADMIN_TOKEN="${ADMIN_TOKEN:?ADMIN_TOKEN env var required}"
PRIVATE_KEY="${FIRMWARE_SIGNING_KEY:-./firmware_signing_private.pem}"
OTA_HOST="${OTA_HOST:-root@192.168.176.120}"
MOCK_VERSION="${MOCK_VERSION:-99.0.0}"
MOCK_CHANNEL="${MOCK_CHANNEL:-stable}"

# Find a binary to use as the mock payload
if [[ -n "${1:-}" ]]; then
  BIN="$1"
elif [[ -f "../kill-energy-bill/firmware-v0.1.3.bin" ]]; then
  BIN="../kill-energy-bill/firmware-v0.1.3.bin"
else
  echo "No binary provided and ../kill-energy-bill/firmware-v0.1.3.bin not found."
  echo "Usage: $0 [path/to/firmware.bin]"
  exit 1
fi

[[ -f "$BIN" ]]         || { echo "Binary not found: $BIN"; exit 1; }
[[ -f "$PRIVATE_KEY" ]] || { echo "Signing key not found: $PRIVATE_KEY"; exit 1; }

echo "==> Mock OTA release"
echo "    Binary:  $BIN"
echo "    Version: $MOCK_VERSION (channel: $MOCK_CHANNEL)"
echo ""

# SHA-256
SHA256=$(sha256sum "$BIN" | awk '{print $1}')
echo "    SHA256:  $SHA256"

# Ed25519 signature over raw 32-byte hash
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
printf '%s' "$SHA256" | xxd -r -p > "$TMPFILE"
SIG=$(openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$TMPFILE" | base64 -w0)
echo "    Sig:     ${SIG:0:20}..."

# Upload binary to server
REMOTE_PATH="/var/www/firmware/${MOCK_CHANNEL}/killbill-${MOCK_VERSION}.bin"
echo ""
echo "==> Uploading binary to $OTA_HOST:$REMOTE_PATH"
scp "$BIN" "$OTA_HOST:$REMOTE_PATH"

# Publish manifest
echo "==> Publishing manifest..."
RESPONSE=$(curl -fsS -X POST "https://firmware.local-share.com/admin/release" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel\":    \"$MOCK_CHANNEL\",
    \"version\":    \"$MOCK_VERSION\",
    \"sha256\":     \"$SHA256\",
    \"ed25519_sig\":\"$SIG\",
    \"mandatory\":  false,
    \"notes\":      \"Mock release for OTA end-to-end testing\"
  }")
echo "    Response: $RESPONSE"

# Verify
echo ""
echo "==> Verifying /ota/check (against version 0.0.0)..."
curl -fsS "https://firmware.local-share.com/ota/check?version=0.0.0&channel=${MOCK_CHANNEL}" | \
  python3 -m json.tool 2>/dev/null || \
  curl -fsS "https://firmware.local-share.com/ota/check?version=0.0.0&channel=${MOCK_CHANNEL}"

echo ""
echo "==> Done. Flash the ESP32 with firmware v0.1.7 (or any version < $MOCK_VERSION) and"
echo "    monitor serial output — it should detect the update and flash $MOCK_VERSION."
echo ""
echo "    To clean up after testing, delete the mock manifest:"
echo "    ssh $OTA_HOST 'rm /var/www/firmware/${MOCK_CHANNEL}/killbill-${MOCK_VERSION}.bin'"
