# ATH License Bot integration

The iOS app verifies licenses through the Cloudflare Worker endpoint `/api/license/mobile-verify`. The app sends the license key and a Keychain-persisted installation device ID. The Worker performs key status, expiry, and device-limit checks against D1.

## Configure the Worker URL

After deploying `ath-license-bot`, replace `https://YOUR_WORKER.workers.dev` in `ThreeOneOSFive/Info.plist` with the actual Worker URL. Do not add Telegram credentials or `API_HMAC_SECRET` to the iOS target.

## Secrets

Keep these only in Cloudflare Worker secrets:

- `TELEGRAM_BOT_TOKEN`
- `OWNER_TELEGRAM_ID`
- `API_HMAC_SECRET`
- `TELEGRAM_WEBHOOK_SECRET`

The hardened `/api/license/verify` endpoint remains available for trusted server-to-server callers and requires HMAC headers. The mobile endpoint intentionally does not receive the HMAC secret because a mobile app cannot keep a shared secret private; HTTPS, D1 validation, device binding, and Worker rate limiting protect the mobile flow.
