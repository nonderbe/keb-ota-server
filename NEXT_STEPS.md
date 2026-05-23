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

## Pending

### 1. Deploy to server

```bash
./deploy.sh root@192.168.176.120
```

First-time setup on the server (if not already done):
```bash
# Create firmware directories
ssh root@192.168.176.120 'mkdir -p /var/www/firmware/{stable,beta} && chown -R www-data:www-data /var/www/firmware'

# Create env file with admin token (if not present)
ssh root@192.168.176.120 'mkdir -p /etc/ota-server && echo "ADMIN_TOKEN=<secret>" > /etc/ota-server/env && chmod 600 /etc/ota-server/env'

# Install and enable systemd service (if not present)
scp systemd/ota-server.service root@192.168.176.120:/etc/systemd/system/
ssh root@192.168.176.120 'systemctl daemon-reload && systemctl enable ota-server'

# Install nginx config (if not present)
scp nginx/firmware.conf root@192.168.176.120:/etc/nginx/sites-available/firmware.conf
scp nginx/ota-ratelimit.conf root@192.168.176.120:/etc/nginx/conf.d/ota-ratelimit.conf
ssh root@192.168.176.120 'ln -sf /etc/nginx/sites-available/firmware.conf /etc/nginx/sites-enabled/ && nginx -t && systemctl reload nginx'
```

### 2. Smoke-test: release mock firmware and verify device OTA

See `test-mock.sh` — signs and releases a mock binary, then verifies `/ota/check` returns the right payload.

```bash
export ADMIN_TOKEN=<secret>
./test-mock.sh
```

After the server-side check passes, flash the ESP32 with the current firmware
(version 0.1.6) and watch the serial monitor — it should detect the 0.1.7 mock
on the server, download, verify, and attempt to flash.

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
