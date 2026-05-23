# keb-ota-server — Next Steps

## Status

Code is production-ready. Remaining work is operational (deploy + smoke-test).

---

## Completed

- [x] TLS: Cloudflare Tunnel handles TLS termination — no server-side cert management needed
- [x] Root CA extracted from `firmware.local-share.com` chain (GTS Root R4 / GlobalSign Root CA) — embedded in firmware `config.h`
- [x] Ed25519 keypair generated; private key stored offline (not committed)
- [x] `firmware_signing_public.pem` committed to repo
- [x] Raw 32-byte public key (`OTA_SIGNING_PUBKEY`) embedded in firmware `config.h`
- [x] `Manifest`, `CheckResponse`, `ReleasePayload` all carry `sha256` + `ed25519_sig`
- [x] Server-side signature verification in `handleRelease` (catches signing mistakes before any device sees them)
- [x] `saveManifest` auto-creates `/var/www/firmware/<channel>/` directory
- [x] `/health` endpoint for monitoring
- [x] `release.sh` — offline signing + scp upload + manifest publish in one command
- [x] README updated to reflect Ed25519 + SHA256 production state

---

## Completed (2026-05-23)

- [x] Deploy v1.0.0 binary to `root@192.168.176.120` — `keb-ota-server v1.0.0 listening on :8080`
- [x] nginx `/health` location added and reloaded
- [x] `https://firmware.local-share.com/health` → `{"status":"ok","version":"1.0.0"}`
- [x] Firmware v0.1.7 signed and released to stable channel
  - SHA256: `fdb35afff60fcaafd6616aa090498e49ba70abd0d4f6ad99dd675bc03f416aa5`
  - `/ota/check?version=0.1.6&channel=stable` → `update_available: true, version: 0.1.7`
  - `/ota/check?version=0.1.7&channel=stable` → `update_available: false`
- [x] ESP32 (killbill_c085b8) flashed with v0.1.6 via USB (`/dev/cu.usbserial-1440`)
- [x] Device boots correctly, runs v0.1.6 firmware

## Pending

### 1. Device OTA pull (on-device test)

Device is flashed with v0.1.6 and the server has v0.1.7 ready. On the next boot
with WiFi access, the device will automatically detect and flash v0.1.7.

Plug the device into its home network (`Van Houtte 27`) and reset it. Watch serial:
```
[OTA] Update beschikbaar: 0.1.6 → 0.1.7
[OTA] Firmware geverifieerd en geflasht — herstarten...
```
After reboot the device reports `v0.1.7` in checkin logs on the server.

### 3. firmware.kill-energy-bill.com — secondary OTA server

The secondary OTA URL in `config.h` is `https://firmware.kill-energy-bill.com`.
Domain is not live yet. When it is:

1. Extract root CA:
   ```bash
   openssl s_client -connect firmware.kill-energy-bill.com:443 -showcerts 2>/dev/null | tail -c 3000
   ```
2. If it differs from `OTA_TLS_CA_CERT` in `config.h`, add a second constant and update `ota.cpp`.
3. Point the domain's DNS to the same Cloudflare Tunnel (or a second server).

---

## Monitoring

Once deployed, the `/health` endpoint can be polled by any uptime monitor:
```
https://firmware.local-share.com/health
```
Expected response: `{"status":"ok","version":"1.0.0"}`
