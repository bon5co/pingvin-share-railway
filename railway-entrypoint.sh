#!/bin/sh
# Pingvin Share X on Railway.
#
# Five things happen here that the stock image cannot do for itself:
#
#   1. The listener. Caddy's baked Caddyfile is nailed to `:3000` and the
#      frontend to `:3333`; `$PORT` is NOT a listen port anywhere — it is the
#      UPSTREAM Caddy proxies non-/api requests to, and the backend's port when
#      BACKEND_PORT is unset. Railway injects PORT into every service, so the
#      stock image with Railway's PORT=8080 makes Caddy proxy every page to the
#      NestJS backend and the whole UI answers
#        {"message":"Cannot GET /","error":"Not Found","statusCode":404}
#      while /api/health stays green. Here the injected value is captured as the
#      LISTEN port for a generated Caddyfile, and PORT/BACKEND_PORT are pinned to
#      the values the upstream scripts expect.
#   2. The admin account. Pingvin's first signup gets isAdmin=true and
#      share.allowRegistration defaults to "true", so on a stock deploy the first
#      stranger to open the public URL owns the instance. Seeded here from the
#      environment before Caddy is ever started, so the first request the public
#      port ever serves is already against a claimed instance.
#   3. general.appUrl, which defaults to http://localhost:3000 and is what
#      emailed share links, password-reset links and every OAuth redirect_uri are
#      built from.
#   4. Branding on the volume. Logos, favicon and PWA icons are written to
#      /opt/app/frontend/public/img, NOT to the data directory, so on Railway's
#      one volume per service a custom logo is silently reverted to the stock one
#      on every redeploy. That path is relocated onto the volume as a symlink.
#   5. TRUST_PROXY, without which the 20-per-5-minutes login throttle keys every
#      request in the world into one bucket.
set -eu

log() { echo "[railway-entrypoint] $*"; }

DATA_DIR="${PINGVIN_DATA_DIR:-/opt/app/backend/data}"
IMG_DIR="${PINGVIN_IMG_DIR:-$DATA_DIR/img}"
PUBLIC_IMG=/opt/app/frontend/public/img

# ---------------------------------------------------------------- root stage --
# create-user.sh (the stock ENTRYPOINT) re-runs this script as $PUID, so
# everything below the exec runs unprivileged.
if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$DATA_DIR" "$IMG_DIR"

    # Relocate the branding directory onto the volume. Done as a symlink because
    # Railway allows exactly one volume per service and the SQLite database and
    # the uploads both live under $DATA_DIR.
    if [ ! -L "$PUBLIC_IMG" ]; then
        rm -rf "$PUBLIC_IMG"
        ln -s "$IMG_DIR" "$PUBLIC_IMG"
        log "relocated $PUBLIC_IMG -> $IMG_DIR"
    fi

    # create-user.sh chowns $DATA_DIR recursively, which covers $IMG_DIR, but do
    # it here as well so the ownership is right even if that script changes.
    chown -R "${PUID:-1000}:${PGID:-1000}" "$DATA_DIR"
    log "volume ready owner=$(stat -c %u:%g "$DATA_DIR")"

    exec sh /opt/app/scripts/docker/create-user.sh /usr/local/bin/railway-entrypoint.sh
fi

# ---------------------------------------------------------------- app stage --
cd /opt/app

LISTEN="${PORT:-8080}"
BACKEND_PORT="${BACKEND_PORT:-8081}"
FRONTEND_PORT="${FRONTEND_PORT:-3333}"

# Railway's injected port is 8080 today but is not promised to be; the two
# in-container ports must never collide with it, or Caddy dies on
# `bind: address already in use` after everything else has come up healthy.
[ "$BACKEND_PORT" = "$LISTEN" ] && BACKEND_PORT=$((LISTEN + 1))
# The frontend's port is hardcoded in the stock entrypoint
# (`PORT=3333 node frontend/server.js`), so it cannot be moved — only reported.
[ "$FRONTEND_PORT" = "$LISTEN" ] && log "WARNING: injected PORT is $LISTEN, which the frontend also binds"

if [ -z "${PINGVIN_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: PINGVIN_ADMIN_PASSWORD is empty. Refusing to boot: Pingvin gives"
    log "ERROR: administrator rights to whoever signs up first, so an unseeded"
    log "ERROR: instance is claimable by any visitor. Set the variable and redeploy."
    exit 1
fi

# The upstream scripts read PORT as the frontend's upstream, never as a listen
# port. Pin both, and keep Caddy out of their hands so nothing binds the public
# port until the admin account exists.
export PORT="$FRONTEND_PORT"
export BACKEND_PORT
export CADDY_DISABLED=true
export TRUST_PROXY="${TRUST_PROXY:-true}"
export XDG_CONFIG_HOME=/tmp XDG_DATA_HOME=/tmp

log "listen=$LISTEN frontend=$FRONTEND_PORT backend=$BACKEND_PORT trust_proxy=$TRUST_PROXY"

sh /opt/app/scripts/docker/entrypoint.sh &
APP_PID=$!

API="http://127.0.0.1:${BACKEND_PORT}/api"
ready=0
i=0
while [ "$i" -lt 180 ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "application exited during startup"
        wait "$APP_PID" || exit $?
        exit 1
    fi
    if curl -fsS -o /dev/null "${API}/health" 2>/dev/null; then ready=1; break; fi
    sleep 1
    i=$((i + 1))
done
[ "$ready" = 1 ] && log "backend healthy on 127.0.0.1:${BACKEND_PORT}" \
    || log "backend did not answer /api/health in 180s, continuing anyway"

# ------------------------------------------------------- first-boot seeding --
JAR=/tmp/pingvin-cookies
rm -f "$JAR"
authed=0

if [ "$ready" = 1 ]; then
    login_code=$(curl -s -c "$JAR" -o /tmp/pingvin-login.json -w '%{http_code}' \
        -X POST "${API}/auth/signIn" -H 'Content-Type: application/json' \
        -d "$(printf '{"email":"%s","password":"%s"}' \
            "${PINGVIN_ADMIN_EMAIL:-admin@pingvin.local}" "$PINGVIN_ADMIN_PASSWORD")" || echo 000)

    if [ "$login_code" = "200" ]; then
        authed=1
        log "admin account already present, signed in"
    else
        signup_code=$(curl -s -c "$JAR" -o /tmp/pingvin-signup.json -w '%{http_code}' \
            -X POST "${API}/auth/signUp" -H 'Content-Type: application/json' \
            -d "$(printf '{"username":"%s","email":"%s","password":"%s"}' \
                "${PINGVIN_ADMIN_USERNAME:-admin}" \
                "${PINGVIN_ADMIN_EMAIL:-admin@pingvin.local}" \
                "$PINGVIN_ADMIN_PASSWORD")" || echo 000)
        case "$signup_code" in
            200|201)
                authed=1
                log "administrator '${PINGVIN_ADMIN_USERNAME:-admin}' created" ;;
            403)
                log "WARNING: signup is closed and PINGVIN_ADMIN_PASSWORD does not match the stored administrator password. The password is applied only when the account is first created; change it from the account settings page instead." ;;
            *)
                log "WARNING: administrator bootstrap returned $signup_code: $(head -c 200 /tmp/pingvin-signup.json 2>/dev/null)" ;;
        esac
    fi
fi

if [ "$authed" = 1 ]; then
    app_url="${PINGVIN_APP_URL:-}"
    if [ -z "$app_url" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        app_url="https://${RAILWAY_PUBLIC_DOMAIN}"
    fi
    body='['
    [ -n "$app_url" ] && body="${body}{\"key\":\"general.appUrl\",\"value\":\"${app_url}\"},"
    body="${body}{\"key\":\"general.secureCookies\",\"value\":${PINGVIN_SECURE_COOKIES:-true}},"
    body="${body}{\"key\":\"share.allowRegistration\",\"value\":${PINGVIN_ALLOW_REGISTRATION:-false}}]"

    cfg_code=$(curl -s -b "$JAR" -o /tmp/pingvin-config.json -w '%{http_code}' \
        -X PATCH "${API}/configs/admin" -H 'Content-Type: application/json' \
        -d "$body" || echo 000)
    if [ "$cfg_code" = "200" ]; then
        log "config applied: appUrl=${app_url:-<unchanged>} allowRegistration=${PINGVIN_ALLOW_REGISTRATION:-false} secureCookies=${PINGVIN_SECURE_COOKIES:-true}"
    else
        log "WARNING: config update returned $cfg_code: $(head -c 200 /tmp/pingvin-config.json 2>/dev/null)"
    fi
fi
rm -f "$JAR" /tmp/pingvin-login.json /tmp/pingvin-signup.json

# -------------------------------------------------------------- public port --
# Generated rather than using the baked Caddyfile, which listens on a hardcoded
# :3000 and reads the frontend upstream from $PORT.
cat > /tmp/Caddyfile <<EOF
{
	admin off
	auto_https off
}

:${LISTEN} {
	reverse_proxy /api/* http://127.0.0.1:${BACKEND_PORT} {
		trusted_proxies 0.0.0.0/0
	}

	reverse_proxy /* http://127.0.0.1:${FRONTEND_PORT} {
		trusted_proxies 0.0.0.0/0
	}
}
EOF

# Caddy becomes pid 1's foreground process below, so if the app dies the
# container must die with it — otherwise the healthcheck keeps passing against a
# proxy with nothing behind it.
(
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 5; done
    log "application exited, stopping the proxy"
    kill 1 2>/dev/null || true
) &

log "serving on :${LISTEN}"
exec caddy run --adapter caddyfile --config /tmp/Caddyfile
