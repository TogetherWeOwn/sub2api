#!/bin/sh
# CF-1: run CPA (port 8317) and Keeper (port 8080) co-located, with Litestream
# replicating Keeper's SQLite to object storage every 10s.
#
# Required environment:
#   OBJECTSTORE_ENDPOINT / OBJECTSTORE_BUCKET / OBJECTSTORE_ACCESS_KEY /
#     OBJECTSTORE_SECRET_KEY: the S3-compatible state store. CPA keeps its
#     config and logins there; Litestream replicates Keeper's database into
#     the same bucket under the keeper/ prefix, so no extra credentials exist.
#   CPA_MANAGEMENT_KEY: CPA management key (>= 32 chars); also given to Keeper
#     so it can poll CPA over loopback.
#   KEEPER_LOGIN_PASSWORD: Keeper dashboard login password (>= 8 chars).
#     Keeper's login protection stays on; there is no anonymous mode.
#
# Boot order: CPA config -> Keeper -> wait for /data/app.db -> Litestream
# (restores the DB first when the local disk is empty) -> CPA in the
# foreground. Litestream's restore-if-db-not-exists means a fresh container
# with an existing replica resumes history instead of starting empty.
set -eu

for name in OBJECTSTORE_ENDPOINT OBJECTSTORE_BUCKET OBJECTSTORE_ACCESS_KEY OBJECTSTORE_SECRET_KEY CPA_MANAGEMENT_KEY KEEPER_LOGIN_PASSWORD; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "entrypoint: $name is not set" >&2
    exit 64
  fi
done

if ! printf '%s' "$CPA_MANAGEMENT_KEY" | grep -Eq '^[A-Za-z0-9_-]{32,}$'; then
  echo "entrypoint: CPA_MANAGEMENT_KEY must be at least 32 characters of A-Z a-z 0-9 _ -" >&2
  exit 64
fi

if [ "${#KEEPER_LOGIN_PASSWORD}" -lt 8 ]; then
  echo "entrypoint: KEEPER_LOGIN_PASSWORD must be at least 8 characters" >&2
  exit 64
fi

# Writes the first-boot config, then runs CPA with its config and logins kept in object storage.
# CPA only uses this file when the bucket has no config yet; after that the bucket copy wins.
# usage-statistics-enabled is what feeds Keeper; allow-remote lets Keeper (a
# separate process, even on loopback) reach the management API.
cat > /CLIProxyAPI/config.example.yaml <<EOF
config-version: 8
server:
  host: ""
  port: 8317
management:
  allow-remote: true
  secret-key: "${CPA_MANAGEMENT_KEY}"
  disable-control-panel: false
  disable-auto-update-panel: true
access:
  api-keys: []
routing:
  retry:
    request-retry: 1
observability:
  logs:
    debug: false
    logging-to-file: false
    request-log: false
  usage:
    usage-statistics-enabled: true
EOF
chmod 600 /CLIProxyAPI/config.example.yaml

CPA_PID=""
LITESTREAM_PID=""
KEEPER_PID=""
shutdown() {
  kill ${CPA_PID:-} ${LITESTREAM_PID:-} ${KEEPER_PID:-} 2>/dev/null || true
}
trap shutdown TERM INT

mkdir -p /data

# Litestream replicates through the same S3-compatible endpoint as CPA, so the
# entrypoint's OBJECTSTORE_* settings are the only credentials involved.
# part-size keeps uploads on single PUTs: the state shim has no multipart API.
# sync-interval is the owner-ordered 10s (CF-1 CORRECTION 2026-10-13).
cat > /etc/litestream.yml <<EOF
dbs:
  - path: /data/app.db
    restore-if-db-not-exists: true
    replica:
      url: s3://${OBJECTSTORE_BUCKET}/keeper/app.db?endpoint=${OBJECTSTORE_ENDPOINT}&force-path-style=true&region=auto
      sync-interval: 10s
      part-size: 512MB
EOF
chmod 600 /etc/litestream.yml

export AWS_ACCESS_KEY_ID="${OBJECTSTORE_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${OBJECTSTORE_SECRET_KEY}"

WORK_DIR=/data \
CPA_BASE_URL=http://127.0.0.1:8317 \
CPA_MANAGEMENT_KEY="${CPA_MANAGEMENT_KEY}" \
APP_PORT=8080 \
LOGIN_PASSWORD="${KEEPER_LOGIN_PASSWORD}" \
GIN_MODE=release \
/keeper/cpa-usage-keeper &
KEEPER_PID=$!

for _ in $(seq 1 60); do
  [ -f /data/app.db ] && break
  sleep 1
done
if [ ! -f /data/app.db ]; then
  echo "entrypoint: Keeper did not create /data/app.db within 60s" >&2
  kill "$KEEPER_PID" 2>/dev/null || true
  exit 69
fi

litestream replicate -config /etc/litestream.yml &
LITESTREAM_PID=$!

/CLIProxyAPI/CLIProxyAPI &
CPA_PID=$!
wait "$CPA_PID"
STATUS=$?
kill "$LITESTREAM_PID" "$KEEPER_PID" 2>/dev/null || true
wait 2>/dev/null || true
exit "$STATUS"
