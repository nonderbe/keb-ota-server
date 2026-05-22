# OTA Server — Next Steps: Firmware Signing & TLS

## Context

The client currently uses `setInsecure()` on all HTTPS connections, meaning a MITM
attacker can push arbitrary firmware to any device. The fix requires two independent
layers: proper TLS validation (Layer 1) and Ed25519 firmware signature verification
(Layer 2). This document covers the server-side work for both.

---

## Layer 1 — TLS

### Current state

**Confirmed: Cloudflare Tunnel handles TLS.** The server speaks plain HTTP on port 80;
the `cloudflared` daemon establishes an outbound encrypted tunnel to Cloudflare's edge,
which terminates TLS for `firmware.local-share.com`. No nginx or server-side TLS
changes are needed.

The nginx `listen 80;` config is intentional and correct. Do not add Let's Encrypt
or local certificates — it would conflict with the tunnel setup.

### Required action (server side)

None — TLS infrastructure is already in place.

### Required action (firmware team)

The firmware client must embed the root CA that Cloudflare uses to sign the TLS
certificate for `firmware.local-share.com`. Cloudflare Universal SSL typically
chains to a DigiCert root, but the exact root varies. Extract it from the live
endpoint:

```bash
# Show the full cert chain
openssl s_client -connect firmware.local-share.com:443 -showcerts 2>/dev/null

# Show only the issuer of the leaf cert (to identify which CA to trace)
openssl s_client -connect firmware.local-share.com:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```

The root CA PEM (the last cert in the chain) is what goes into firmware. Hand it
to the firmware team as a raw PEM string. See the firmware NEXT_STEPS for how it
gets embedded.

**Important:** Cloudflare rotates leaf certificates automatically, but the root CA
changes rarely (years). Embedding the root CA — not the leaf — is stable.

**Also check:** `firmware.kill-energy-bill.com` (the secondary OTA server in the
firmware config) needs the same treatment. If it's behind the same Cloudflare
account it will likely use the same root CA; confirm with the same `openssl` command.

### Why Cloudflare tunnel does NOT eliminate the need for signing (Layer 2)

Cloudflare sits between the device and the server and terminates TLS. This means:
- Cloudflare sees the plaintext firmware bytes in transit through the tunnel
- A compromised Cloudflare account, a BGP-level redirect to a fake Cloudflare edge,
  or a rogue Cloudflare employee could in principle serve modified firmware

TLS validation prevents passive MITM on the local network. Ed25519 signature
verification (Layer 2) is the protection against everything upstream of the device,
including Cloudflare itself. Both layers are needed.

---

## Layer 2 — Ed25519 Firmware Signing

### Overview

Signing happens **offline** during the release process — the private key never
touches the server or Cloudflare. The server stores and forwards the signature;
it cannot forge one. The device verifies the signature against a public key baked
into the firmware binary.

### Step 1 — Generate keypair (one-time, offline)

```bash
# Keep private.pem offline or in a secrets manager. Never commit it.
openssl genpkey -algorithm ed25519 -out firmware_signing_private.pem
openssl pkey -in firmware_signing_private.pem -pubout -out firmware_signing_public.pem

# Extract raw 32-byte public key as a C byte array for embedding in firmware
openssl pkey -in firmware_signing_public.pem -pubin -outform DER \
  | tail -c 32 | xxd -i
```

The `xxd -i` output is what goes into `config.h` on the firmware side.
Commit `firmware_signing_public.pem` to this repo. Add `firmware_signing_private.pem`
to `.gitignore` and store it securely (password manager, encrypted USB, CI secret).

### Step 2 — Add SHA256 + signature fields to main.go

Replace `MD5` with `SHA256` and add `Ed25519Sig` across all three structs:

```go
type Manifest struct {
    Version    string    `json:"version"`
    URL        string    `json:"url"`
    SHA256     string    `json:"sha256"`       // hex string, replaces md5
    Ed25519Sig string    `json:"ed25519_sig"`  // base64 (std encoding), signs the SHA256 bytes
    Mandatory  bool      `json:"mandatory"`
    Notes      string    `json:"notes"`
    ReleasedAt time.Time `json:"released_at"`
}

type CheckResponse struct {
    UpdateAvailable bool   `json:"update_available"`
    Version         string `json:"version,omitempty"`
    URL             string `json:"url,omitempty"`
    SHA256          string `json:"sha256,omitempty"`
    Ed25519Sig      string `json:"ed25519_sig,omitempty"`
    Mandatory       bool   `json:"mandatory,omitempty"`
    Notes           string `json:"notes,omitempty"`
}

type ReleasePayload struct {
    Channel    string `json:"channel"`
    Version    string `json:"version"`
    SHA256     string `json:"sha256"`
    Ed25519Sig string `json:"ed25519_sig"`
    Mandatory  bool   `json:"mandatory"`
    Notes      string `json:"notes"`
}
```

The server does not need to verify the signature — it stores and forwards it.
Only the firmware verifies it. Thread `SHA256` and `Ed25519Sig` through
`handleRelease` → `saveManifest` → `loadManifest` → `handleCheck` → `CheckResponse`.

Keep the old `MD5` field in `Manifest` (read from existing JSON) but remove it from
`CheckResponse` so it stops being sent to devices. This avoids breaking the manifest
files that are already on disk for one release cycle. Remove it entirely in the
release after signing ships.

### Step 3 — Add server-side signature verification in handleRelease

The server can verify the Ed25519 signature at release time using Go's standard
library. This catches mistakes in the signing script before any device tries to
flash bad firmware.

```go
import (
    "crypto/ed25519"
    "crypto/x509"
    "encoding/base64"
    "encoding/hex"
    "encoding/pem"
    "os"
)

// Load public key once at startup (or embed as a constant)
func loadSigningPubKey(path string) (ed25519.PublicKey, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return nil, err
    }
    block, _ := pem.Decode(data)
    pub, err := x509.ParsePKIXPublicKey(block.Bytes)
    if err != nil {
        return nil, err
    }
    return pub.(ed25519.PublicKey), nil
}

// In handleRelease, after decoding payload and before saveManifest:
hashBytes, err := hex.DecodeString(p.SHA256)
if err != nil || len(hashBytes) != 32 {
    http.Error(w, "invalid sha256", http.StatusBadRequest)
    return
}
sigBytes, err := base64.StdEncoding.DecodeString(p.Ed25519Sig)
if err != nil || len(sigBytes) != 64 {
    http.Error(w, "invalid ed25519_sig", http.StatusBadRequest)
    return
}
if !ed25519.Verify(signingPubKey, hashBytes, sigBytes) {
    http.Error(w, "signature verification failed", http.StatusForbidden)
    return
}
```

Store the public key PEM at `/etc/ota-server/firmware_signing_public.pem` on the
server, or embed it as a string constant in `main.go`.

### Step 4 — Release script

Replace the manual admin curl with a `release.sh` script that handles signing:

```bash
#!/bin/bash
# release.sh — build, sign, upload, and publish a firmware release
# Usage: ./release.sh <channel> <version> <path/to/firmware.bin>
#
# Required env vars:
#   ADMIN_TOKEN             — OTA server admin token
#   FIRMWARE_SIGNING_KEY    — path to firmware_signing_private.pem (default: ./firmware_signing_private.pem)
#   OTA_HOST                — SSH host for binary upload (default: root@192.168.176.120)
set -e

CHANNEL="${1:?Usage: $0 <channel> <version> <firmware.bin>}"
VERSION="${2:?}"
BIN="${3:?}"
ADMIN_TOKEN="${ADMIN_TOKEN:?ADMIN_TOKEN env var required}"
PRIVATE_KEY="${FIRMWARE_SIGNING_KEY:-./firmware_signing_private.pem}"
OTA_HOST="${OTA_HOST:-root@192.168.176.120}"

[[ -f "$BIN" ]]          || { echo "Binary not found: $BIN"; exit 1; }
[[ -f "$PRIVATE_KEY" ]]  || { echo "Signing key not found: $PRIVATE_KEY"; exit 1; }

# Compute SHA256 of firmware binary
SHA256=$(sha256sum "$BIN" | awk '{print $1}')
echo "SHA256: $SHA256"

# Sign: Ed25519 signature over the raw 32-byte SHA256 hash
TMPFILE=$(mktemp)
echo -n "$SHA256" | xxd -r -p > "$TMPFILE"
SIG=$(openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$TMPFILE" | base64 -w0)
rm "$TMPFILE"
echo "Signature: ${SIG:0:16}..."

# Upload binary to server
REMOTE_PATH="/var/www/firmware/${CHANNEL}/killbill-${VERSION}.bin"
echo "Uploading $BIN → $OTA_HOST:$REMOTE_PATH"
scp "$BIN" "$OTA_HOST:$REMOTE_PATH"

# Publish manifest via admin API
echo "Publishing manifest..."
curl -sf -X POST https://firmware.local-share.com/admin/release \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"channel\": \"$CHANNEL\",
    \"version\": \"$VERSION\",
    \"sha256\": \"$SHA256\",
    \"ed25519_sig\": \"$SIG\",
    \"mandatory\": false,
    \"notes\": \"\"
  }"

echo ""
echo "Released $VERSION to $CHANNEL"
echo "Verify: curl https://firmware.local-share.com/ota/check?version=0.0.0&channel=$CHANNEL"
```

Add to `.gitignore`:
```
firmware_signing_private.pem
```

---

## Checklist

- [x] TLS termination confirmed (Cloudflare Tunnel — no server changes needed)
- [x] Extract root CA PEM from `firmware.local-share.com` cert chain; share with firmware team
      → GTS Root R4 cross-signed by GlobalSign Root CA (embedded in firmware config.h)
- [ ] Check `firmware.kill-energy-bill.com` uses same root CA; confirm with firmware team
      → domain unreachable at time of writing; confirm when live
- [x] Generate Ed25519 keypair; store private key securely (out of repo)
      → firmware_signing_private.pem generated locally; in .gitignore
- [x] Commit `firmware_signing_public.pem` to repo
- [x] Share raw 32-byte public key (`xxd -i` output) with firmware team
      → embedded in firmware config.h as OTA_SIGNING_PUBKEY
- [x] Add SHA256 + Ed25519Sig to Manifest, CheckResponse, ReleasePayload in main.go
- [x] Deprecate MD5 in CheckResponse (keep reading it from disk for one cycle)
- [x] Add server-side signature verification in handleRelease
- [x] Write release.sh; add private key to .gitignore
- [ ] Deploy updated server
- [ ] Smoke-test: release a test binary, verify /ota/check returns sha256 + ed25519_sig

---

## Pending: TLS cert pinning for kill-energy-bill.com cloud API

The firmware calls `https://kill-energy-bill.com/api/v1/` from two places
(`doCloudRegister` and `pollCloudCommands` in `KillEnergyBillArduino.ino`).
Both currently use `client.setInsecure()` because the domain is not live yet —
so there is no active risk (DNS fails, nothing is transmitted).

**When `kill-energy-bill.com` goes live, do this before the domain serves real traffic:**

1. Extract the root CA from the cert chain:
   ```bash
   openssl s_client -connect kill-energy-bill.com:443 -showcerts 2>/dev/null
   ```
   The last certificate in the output is the root CA to embed.

2. Add it to `firmware/config.h` (kill-energy-bill repo):
   ```cpp
   static const char CLOUD_TLS_CA_CERT[] PROGMEM = R"EOF(
   -----BEGIN CERTIFICATE-----
   <paste root CA PEM here>
   -----END CERTIFICATE-----
   )EOF";
   ```
   If it is the same root as `OTA_TLS_CA_CERT` (both behind Cloudflare/Google),
   you can reuse that constant instead of adding a new one.

3. In `KillEnergyBillArduino.ino`, replace both `setInsecure()` calls that have a
   `TODO: setCACert(CLOUD_TLS_CA_CERT)` comment with:
   ```cpp
   client.setCACert(CLOUD_TLS_CA_CERT);
   ```

4. Build, flash, and verify the cloud registration still succeeds.
