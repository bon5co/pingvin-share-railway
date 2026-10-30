# pingvin-share-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/pingvin-share-x-v122-or-wetransfer-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Pingvin Share X template](https://railway.com/deploy/pingvin-share-x-v122-or-wetransfer-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Railway-tuned [Pingvin Share X](https://github.com/smp46/pingvin-share-x) image, published as
`ghcr.io/bon5co/pingvin-share-railway:latest`.

Pingvin Share is a self-hosted file-sharing service — a WeTransfer alternative with expiring
links, password-protected shares, visitor limits, reverse shares and OIDC/LDAP login.

## Why this image exists

The Railway marketplace listings for this app all deploy `stonith404/pingvin-share`, which
upstream **archived on 2025-06-29**; its `latest` tag and its `v1.13.0` tag are the same digest,
pushed 2025-05-25. Upstream's own README points at the `smp46/pingvin-share-x` fork, which this
image is built from — 24 releases and 221 commits ahead.

Four fixes on top of it, each of which the existing listings need and none of which can be
expressed as a Railway variable:

1. **The listener.** Caddy's baked Caddyfile is nailed to `:3000` and the frontend to `:3333`.
   `$PORT` is not a listen port anywhere — it is the upstream Caddy proxies non-`/api` requests
   to. Railway injects `PORT` into every service, so a stock deploy makes Caddy proxy every page
   to the NestJS backend and the entire UI answers
   `{"message":"Cannot GET /","error":"Not Found","statusCode":404}` while `/api/health` stays
   green. The entrypoint captures the injected port for a generated Caddyfile and pins the two
   internal ports.
2. **The admin account.** The first signup gets `isAdmin: true` and `share.allowRegistration`
   defaults to `true`, so a stock deploy belongs to whichever stranger opens the URL first. The
   account is seeded from `PINGVIN_ADMIN_PASSWORD` before the public port is ever bound, and the
   container refuses to boot on an empty password.
3. **Branding on the volume.** Logos, favicon and PWA icons are written to
   `/opt/app/frontend/public/img`, not to the data directory, so with one Railway volume a custom
   logo is reverted to the stock one on every redeploy. That path is relocated onto the volume.
4. **`general.appUrl` and `TRUST_PROXY`.** `appUrl` defaults to `http://localhost:3000` and is
   what emailed share links, password-reset links and every OAuth `redirect_uri` are built from.
   Without `TRUST_PROXY=true` the 20-per-5-minutes login throttle keys every request on earth
   into one bucket — 20 wrong passwords lock out every legitimate user.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PINGVIN_ADMIN_PASSWORD` | *(none — required)* | Password for the seeded administrator. Boot fails without it. |
| `PINGVIN_ADMIN_EMAIL` | `admin@pingvin.local` | Login email for that account. |
| `PINGVIN_ADMIN_USERNAME` | `admin` | Username for that account. |
| `PINGVIN_ALLOW_REGISTRATION` | `false` | Seeds `share.allowRegistration`. |
| `PINGVIN_SECURE_COOKIES` | `true` | Seeds `general.secureCookies` (Railway terminates TLS). |
| `PINGVIN_APP_URL` | `https://$RAILWAY_PUBLIC_DOMAIN` | Seeds `general.appUrl`. |

Everything else is Pingvin's own DB-backed configuration and stays editable in the admin UI.

Volume: `/opt/app/backend/data` (SQLite database, uploads, and the relocated branding directory).
Public port: whatever Railway injects as `PORT`. Healthcheck: `/api/health`.
