## Railway-tuned Pingvin Share X.
#
# Base image is the MAINTAINED fork (smp46/pingvin-share-x), not stonith404's
# pingvin-share: upstream archived that repository on 2025-06-29 and its own
# README points at this fork. The archived image's `latest` tag and its
# `v1.13.0` tag are the same digest, pushed 2025-05-25.
FROM ghcr.io/smp46/pingvin-share-x:v1.22.0

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Baked, NOT published as template variables: templateGenerate drops a variable
# whose default is a literal and republishes it as a blank REQUIRED field on the
# deploy form. Only values that genuinely belong to the deployer stay variables,
# and those are Railway expressions (${{secret(n)}}, ${{RAILWAY_PUBLIC_DOMAIN}}),
# whose defaults survive.
#
# PINGVIN_LISTEN_PORT is deliberately absent: the listener is whatever Railway
# injects as $PORT, captured by the entrypoint before $PORT is handed to the
# upstream scripts, which read it as the frontend's UPSTREAM port rather than as
# a listen port.
ENV BACKEND_PORT=8081 \
    FRONTEND_PORT=3333 \
    TRUST_PROXY=true \
    DATA_DIRECTORY=/opt/app/backend/data \
    PINGVIN_DATA_DIR=/opt/app/backend/data \
    PINGVIN_IMG_DIR=/opt/app/backend/data/img \
    PINGVIN_ADMIN_EMAIL=admin@pingvin.local \
    PINGVIN_ADMIN_USERNAME=admin \
    PINGVIN_ALLOW_REGISTRATION=false \
    PINGVIN_SECURE_COOKIES=true \
    PUID=1000 \
    PGID=1000

# The stock image's ENTRYPOINT (create-user.sh) is still used — this script
# re-execs itself through it — so the ownership repair and the privilege drop
# upstream already does are kept rather than replaced.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
