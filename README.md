# keb-ota-server v1.0.0

Over-the-air firmware update server for Kill Energy Bill ESP32 devices.

Written in Go with no external dependencies. Served behind a Cloudflare Tunnel;
nginx handles static binary serving and rate limiting.

---

## Architecture

```
ESP32 device
    │
    │ HTTPS (TLS terminated at Cloudflare edge)
    ▼
Cloudflare Edge  ←── firmware.local-share.com DNS → Cloudflare
    │
    │ cloudflared tunnel (encrypted, outbound from server)
    ▼
nginx :80  (Proxmox LXC, 192.168.176.120)
    ├── /files/*     → static .bin files from /var/www/firmware/
    ├── /ota/*       → rate-limited proxy → Go server :8080
    └── /admin/*     → proxy → Go server :8080
                              │
                       Go OTA server :8080
                          (ota-server binary)
```

**TLS is handled entirely by Cloudflare.** The server speaks plain HTTP on port 80;
no certificates are managed on the host. The tunnel is established by `cloudflared`
(configured separately, not in this repo).

---

## Security model

| Layer | Mechanism |
|-------|-----------|
| Transport | Cloudflare Tunnel — TLS terminated at edge, encrypted in transit |
| Firmware integrity | SHA-256 hash verified by device after download |
| Firmware authenticity | Ed25519 signature verified by device before flashing |
| Admin endpoint | `X-Admin-Token` header (set in `/etc/ota-server/env`) |
| Rate limiting | 6 req/min per IP on `/ota/` (nginx) |
| Process isolation | `www-data`, `NoNewPrivileges=yes` |

**Signing is fully offline.** The Ed25519 private key never touches the server.
The server stores and forwards the signature; it cannot forge one.
The device verifies the signature against a public key baked into the firmware.
A compromised server cannot push malicious firmware.

---

## On-disk layout (server)

```
/var/www/firmware/
├── stable/
│   ├── manifest.json           ← written by Go server on /admin/release
│   └── killbill-0.1.7.bin     ← uploaded via scp before calling /admin/release
└── beta/
    ├── manifest.json
    └── killbill-0.1.8-beta.bin

/opt/ota-server/
└── ota-server                  ← compiled Go binary (deployed via deploy.sh)

/etc/ota-server/env
└── ADMIN_TOKEN=<secret>
```

---

## API

### `GET /health`

Returns `{"status":"ok","version":"1.0.0"}`. Used by monitoring.

### `GET /ota/check`

Polled by devices on boot and every 24 hours.

Query parameters:
| Parameter   | Example            | Description                       |
|-------------|--------------------|-----------------------------------|
| `version`   | `0.1.6`            | Device's current firmware version |
| `channel`   | `stable`           | `stable` or `beta`                |
| `device_id` | `killbill_a1b2c3`  | Logged only, not used for routing |

Response (no update):
```json
{ "update_available": false }
```

Response (update available):
```json
{
  "update_available": true,
  "version": "0.1.7",
  "url": "https://firmware.local-share.com/files/stable/killbill-0.1.7.bin",
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "ed25519_sig": "base64-encoded-64-byte-Ed25519-signature",
  "mandatory": false,
  "notes": "Bugfix: P1 reconnect after router reboot"
}
```

Rate limited: 6 requests/minute per IP.

### `POST /ota/checkin`

Telemetry alongside the update check. Logged only; no business logic.

```json
{
  "device_id": "killbill_a1b2c3",
  "version": "0.1.6",
  "channel": "stable",
  "mac": "AA:BB:CC:DD:EE:FF"
}
```

Response: `204 No Content`

### `POST /admin/release`

Protected by `X-Admin-Token` header. Writes a new `manifest.json` for the
specified channel after verifying the Ed25519 signature. The binary must be
uploaded to the server via `scp` before calling this endpoint.

```json
{
  "channel":     "stable",
  "version":     "0.1.7",
  "sha256":      "hex-sha256-of-firmware.bin",
  "ed25519_sig": "base64-Ed25519-signature-over-sha256-bytes",
  "mandatory":   false,
  "notes":       "Bugfix release"
}
```

Response: `{ "ok": true }`

The server verifies the Ed25519 signature at release time — a misconfigured signing
script is caught before any device downloads bad firmware.

---

## Release workflow

Use `release.sh` — it handles SHA-256 computation, offline signing, binary upload,
and manifest publication in one step.

```bash
export ADMIN_TOKEN=<secret>
export FIRMWARE_SIGNING_KEY=./firmware_signing_private.pem  # never committed
./release.sh stable 0.1.7 .pio/build/esp32-usb/firmware.bin
```

The script:
1. Computes SHA-256 of the firmware binary
2. Signs the raw 32-byte hash with Ed25519 (offline, private key stays local)
3. SCPs the binary to `/var/www/firmware/<channel>/killbill-<version>.bin`
4. Posts to `/admin/release` — server verifies signature and writes manifest

Verify the release:
```bash
curl 'https://firmware.local-share.com/ota/check?version=0.0.0&channel=stable'
```

---

## Deploy (server binary)

```bash
./deploy.sh                        # deploys to root@192.168.176.120 (default)
./deploy.sh user@other-host        # deploys to a different host
```

Cross-compiles for `linux/amd64`, SCPs the binary, restarts the systemd service.

---

## Version comparison

`major × 1_000_000 + minor × 1_000 + patch`

Pre-release suffixes (e.g. `-beta`) are stripped before comparison, so `0.1.7-beta`
compares equal to `0.1.7`. Channel separation (stable vs beta) controls which devices
receive beta builds — both semver values are identical.

---

## Signing keys

`firmware_signing_private.pem` — kept offline (dev machine / secrets manager).
Never committed; listed in `.gitignore`.

`firmware_signing_public.pem` — committed to this repo. The matching raw 32-byte
public key is embedded in the firmware as `OTA_SIGNING_PUBKEY` in `config.h`.
