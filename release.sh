#!/bin/bash
# release.sh — build, sign, and publish a firmware release to the OTA server.
# Usage: ./release.sh <channel> <version> <path/to/firmware.bin>
#
# Required env vars:
#   ADMIN_TOKEN             — OTA server admin token
#
# Optional env vars:
#   FIRMWARE_SIGNING_KEY    — path to firmware_signing_private.pem  (default: ./firmware_signing_private.pem)
#   OTA_HOST                — SSH host for binary upload              (default: root@192.168.176.120)
set -euo pipefail

CHANNEL="${1:?Usage: $0 <channel> <version> <firmware.bin>}"
VERSION="${2:?}"
BIN="${3:?}"
ADMIN_TOKEN="${ADMIN_TOKEN:?ADMIN_TOKEN env var required}"
PRIVATE_KEY="${FIRMWARE_SIGNING_KEY:-./firmware_signing_private.pem}"
OTA_HOST="${OTA_HOST:-root@192.168.176.120}"

[[ -f "$BIN" ]]         || { echo "Binary not found: $BIN"; exit 1; }
[[ -f "$PRIVATE_KEY" ]] || { echo "Signing key not found: $PRIVATE_KEY"; exit 1; }

# Compute SHA-256 of firmware binary (compatible with macOS and Linux)
SHA256=$(openssl dgst -sha256 -hex "$BIN" | awk '{print $2}')
echo "SHA256: $SHA256"

# Sign: Ed25519 signature over the raw 32-byte SHA-256 hash (not the hex string)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
printf '%s' "$SHA256" | xxd -r -p > "$TMPFILE"
SIG=$(openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$TMPFILE" | base64 | tr -d '\n')
echo "Signature: ${SIG:0:16}..."

# Upload binary to server
REMOTE_PATH="/var/www/firmware/${CHANNEL}/killbill-${VERSION}.bin"
echo "Uploading $BIN → $OTA_HOST:$REMOTE_PATH"
scp "$BIN" "$OTA_HOST:$REMOTE_PATH"

# Publish manifest via admin API (server also verifies the signature)
echo "Publishing manifest..."
curl -fsS -X POST "https://firmware.local-share.com/admin/release" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel\":    \"$CHANNEL\",
    \"version\":    \"$VERSION\",
    \"sha256\":     \"$SHA256\",
    \"ed25519_sig\":\"$SIG\",
    \"mandatory\":  false,
    \"notes\":      \"\"
  }"

echo ""
echo "Released $VERSION to channel '$CHANNEL'"
echo "Verify: curl 'https://firmware.local-share.com/ota/check?version=0.0.0&channel=$CHANNEL'"
