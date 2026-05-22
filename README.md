# keb-ota-server

Over-the-air firmware update server for Kill Energy Bill ESP32 devices.

Written in Go with no external dependencies. Served behind a Cloudflare Tunnel,
with nginx handling static binary files and rate limiting.

---

## Architecture

```
ESP32 device
    │
    │ HTTPS (TLS terminated at Cloudflare edge)
    ▼
Cloudflare Edge  ←──  firmware.local-share.com DNS → Cloudflare
    │
    │ cloudflared tunnel (encrypted, outbound from server)
    ▼
nginx : 80  (Proxmox LXC, 192.168.176.120)
    ├── /files/*        → serves .bin files directly from /var/www/firmware/
    ├── /ota/*          → rate-limited proxy → Go server :8080
    └── /admin/*        → proxy → Go server :8080
                                │
                         Go OTA server :8080
                              (ota-server binary)
```

**TLS is handled entirely by Cloudflare.** The server itself only speaks HTTP on
port 80; no certificates are managed on the host. The tunnel is established by the
`cloudflared` daemon (configured separately, not in this repo).

The nginx config (`nginx/firmware.conf`) is intentionally HTTP-only. Do not add
Let's Encrypt or any local TLS — it would conflict with the tunnel.

---

## On-disk layout (server)

```
/var/www/firmware/
├── stable/
│   ├── manifest.json          ← written by Go server on /admin/release
│   └── killbill-0.1.6.bin    ← uploaded manually (see Release workflow)
└── beta/
    ├── manifest.json
    └── killbill-0.1.7-beta.bin
```

`/opt/ota-server/`
```
ota-server          ← compiled Go binary (deployed via deploy.sh)
```

`/etc/ota-server/env`
```
ADMIN_TOKEN=<secret>
```

---

## API endpoints

### `GET /ota/check`

Polled by devices on boot and every 24 hours. Returns whether an update is
available for the device's current version and channel.

Query parameters:
| Parameter   | Example       | Description                          |
|-------------|---------------|--------------------------------------|
| `version`   | `0.1.6`       | Device's current firmware version    |
| `channel`   | `stable`       | `stable` or `beta`                   |
| `device_id` | `killbill_a1b2c3` | Logged only, not used for routing |

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
  "md5": "d41d8cd98f00b204e9800998ecf8427e",
  "mandatory": false,
  "notes": "Bugfix: P1 reconnect after router reboot"
}
```

Rate limited: 6 requests/minute per IP (nginx `ota-ratelimit.conf`).

**Note:** MD5 is currently in the manifest but the firmware client does not verify
it. It will be replaced by SHA-256 + Ed25519 signature. See `NEXT_STEPS.md`.

### `POST /ota/checkin`

Telemetry call made by devices alongside the update check. Logged only; no
business logic.

Request body:
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

Protected by `X-Admin-Token` header (value from `ADMIN_TOKEN` env var).
Writes a new `manifest.json` for the specified channel. The binary must be
uploaded to the server separately before calling this endpoint.

Request body:
```json
{
  "channel": "stable",
  "version": "0.1.7",
  "md5": "d41d8cd98f00b204e9800998ecf8427e",
  "mandatory": false,
  "notes": "Bugfix release"
}
```

Response: `{ "ok": true }`

---

## Release workflow (current)

1. Build firmware: `pio run -e esp32-usb`
2. Compute MD5 of `.bin` file
3. Upload binary to server:
   ```bash
   scp .pio/build/esp32-usb/firmware.bin \
     root@192.168.176.120:/var/www/firmware/stable/killbill-0.1.7.bin
   ```
4. Publish manifest:
   ```bash
   curl -X POST https://firmware.local-share.com/admin/release \
     -H "X-Admin-Token: $ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"channel":"stable","version":"0.1.7","md5":"...","mandatory":false,"notes":"..."}'
   ```

**This workflow will be replaced** with a signing step once Ed25519 support lands.
See `NEXT_STEPS.md` for the planned `release.sh` script.

---

## Deploy (server binary)

```bash
./deploy.sh                        # deploys to root@192.168.176.120 (default)
./deploy.sh user@other-host        # deploys to a different host
```

`deploy.sh` cross-compiles for `linux/amd64`, SCPs the binary, and restarts the
systemd service. The Go server runs as `www-data` with `NoNewPrivileges=yes`
(see `systemd/ota-server.service`).

---

## Version comparison

Versions are compared as semantic version integers:
`major × 1_000_000 + minor × 1_000 + patch`

Pre-release suffixes (e.g. `-beta`) are stripped before comparison. This means
`0.1.7-beta` is treated as `0.1.7` for comparison purposes — channel separation
(stable vs beta) is the primary mechanism for controlling who gets what.

---

## Security posture

| Concern | Current state |
|---------|---------------|
| Transport encryption | Cloudflare Tunnel (TLS at edge) |
| Firmware integrity | MD5 in manifest — **not verified by client** |
| Firmware authenticity | **Not implemented** — no signing |
| Admin endpoint | X-Admin-Token header |
| Rate limiting | 6 req/min per IP on /ota/ |
| Process isolation | www-data, NoNewPrivileges |

Firmware signing (Ed25519) and client-side SHA-256 + signature verification are
the primary open security items. See `NEXT_STEPS.md`.

---

## What's missing / planned

See `NEXT_STEPS.md` for the full plan. Short version:

- Replace MD5 with SHA-256 in manifest and `CheckResponse`
- Add Ed25519 signature field to manifest
- Write `release.sh` that signs firmware offline before publishing
- Optionally: server-side signature verification at release time
