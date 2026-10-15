#!/bin/sh
# Builds the CPA image and runs it against the Worker's S3 shim (src/s3.ts) served by Node:
# management, panel, an API key saved the way the dashboard saves it, the open-when-empty behaviour
# the Worker guards against (src/key-guard.ts), and the config surviving a restart from the bucket.
# Also covers the co-located Keeper (login, version, management-backed status) and Litestream
# replicating Keeper's SQLite into the same bucket under keeper/.
set -eu

IMAGE=${IMAGE:-sub2api-cpa:test}
NODE_IMAGE=node:24-alpine
NET=sub2api-smoke
PORT=18317
KEEPER_PORT=18080
CLIENT_KEY=client-key-0123456789abcdef0123456789abcdef
MANAGEMENT_KEY=management-key-0123456789abcdef0123456789ab
KEEPER_PASSWORD=keeper-pass-0123456789abcdef0123456789abcdef
KEEPER_VERSION=v1.15.11

cleanup() {
  docker rm -f smoke-cpa smoke-s3 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "$JAR" 2>/dev/null || true
}
JAR=$(mktemp)
trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  docker logs smoke-cpa >&2 || true
  docker logs smoke-s3 >&2 || true
  exit 1
}

status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

expect() {
  want=$1
  shift
  got=$(status "$@")
  [ "$got" = "$want" ] || fail "expected $want, got $got for: $*"
  echo "ok $want $*"
}

start_cpa() {
  docker rm -f smoke-cpa >/dev/null 2>&1 || true
  docker run -d --name smoke-cpa --network "$NET" -p "127.0.0.1:$PORT:8317" -p "127.0.0.1:$KEEPER_PORT:8080" \
    -e OBJECTSTORE_ENDPOINT=http://smoke-s3:9000 \
    -e OBJECTSTORE_BUCKET=state \
    -e OBJECTSTORE_ACCESS_KEY=smoke-access \
    -e OBJECTSTORE_SECRET_KEY=smoke-secret-0123456789 \
    -e CPA_MANAGEMENT_KEY="$MANAGEMENT_KEY" \
    -e KEEPER_LOGIN_PASSWORD="$KEEPER_PASSWORD" \
    "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    [ "$(status "http://127.0.0.1:$PORT/healthz")" = 200 ] && return 0
    sleep 1
  done
  fail "CPA did not become healthy"
}

keeper_keys() {
  curl -s "http://127.0.0.1:19000/__keys" | tr ',' '\n' | grep -c 'keeper/' || true
}

docker build -q -t "$IMAGE" container >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name smoke-s3 --network "$NET" -p "127.0.0.1:19000:9000" \
  -v "$(pwd):/app:ro" -w /app "$NODE_IMAGE" node test/s3-server.ts >/dev/null
for _ in $(seq 1 30); do
  [ "$(status http://127.0.0.1:19000/__keys)" = 200 ] && break
  sleep 1
done

base="http://127.0.0.1:$PORT"
kbase="http://127.0.0.1:$KEEPER_PORT"
mgmt="authorization: Bearer $MANAGEMENT_KEY"

wait_for() {
  for _ in $(seq 1 30); do
    eval "$1" && return 0
    sleep 1
  done
  fail "timed out waiting for: $1"
}

start_cpa
expect 200 "$base/healthz"
expect 401 "$base/v8/management/config"
expect 200 -H "$mgmt" "$base/v8/management/config"
expect 200 "$base/management.html"
expect 200 -X PUT -H "$mgmt" -H "content-type: application/json" -d "[\"$CLIENT_KEY\"]" "$base/v8/management/config/access/api-keys"
wait_for '[ "$(status -H "x-api-key: $CLIENT_KEY" "$base/v1/models")" = 200 ]'
echo "ok a key saved the way the dashboard saves it works"
expect 401 "$base/v1/models"
expect 401 -H "authorization: Bearer probe-0123456789abcdef" "$base/v1/models"
expect 200 -H "x-api-key: $CLIENT_KEY" "$base/v1/models"
expect 200 -H "authorization: Bearer $CLIENT_KEY" "$base/v1/models"

if docker run --rm --network "$NET" -e OBJECTSTORE_BUCKET=x "$IMAGE" >/dev/null 2>&1; then
  fail "entrypoint started without its required settings"
fi
echo "ok entrypoint refuses missing settings"

if docker run --rm --network "$NET" \
  -e OBJECTSTORE_ENDPOINT=http://smoke-s3:9000 \
  -e OBJECTSTORE_BUCKET=state \
  -e OBJECTSTORE_ACCESS_KEY=smoke-access \
  -e OBJECTSTORE_SECRET_KEY=smoke-secret-0123456789 \
  -e CPA_MANAGEMENT_KEY="$MANAGEMENT_KEY" \
  "$IMAGE" >/dev/null 2>&1; then
  fail "entrypoint started without KEEPER_LOGIN_PASSWORD"
fi
echo "ok entrypoint refuses a missing Keeper password"

start_cpa
expect 200 -H "x-api-key: $CLIENT_KEY" "$base/v1/models"
expect 401 -H "x-api-key: wrong-key" "$base/v1/models"
echo "ok config survived a restart from the bucket"

expect 200 -X PUT -H "$mgmt" -H "content-type: application/json" -d "[]" "$base/v8/management/config/access/api-keys"
wait_for '[ "$(status -H "authorization: Bearer probe-0123456789abcdef" "$base/v1/models")" = 200 ]'
echo "ok CPA lets every call through once its key list is empty, so the Worker must refuse"

state=$(curl -s -H "$mgmt" "$base/v0/management/anthropic-auth-url" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
[ -n "$state" ] || fail "anthropic-auth-url returned no state"
expect 200 "$base/v0/management/oauth-callback?code=smoke-code&state=$state"
expect 404 "$base/v0/management/oauth-callback?code=smoke-code&state=0123456789abcdef0123456789abcdef"
echo "ok CPA takes a pasted callback by its state alone"

keeper_login() {
  rm -f "$JAR"
  expect 204 -X POST -H "content-type: application/json" -H "X-CPA-Usage-Keeper-Request: fetch" -d "{\"password\":\"$KEEPER_PASSWORD\"}" \
    -c "$JAR" "$kbase/api/v1/auth/login"
  expect 401 -X POST -H "content-type: application/json" -H "X-CPA-Usage-Keeper-Request: fetch" -d '{"password":"wrong-password"}' \
    "$kbase/api/v1/auth/login"
  echo "ok Keeper login accepts the password and refuses a wrong one"
}

wait_for '[ "$(status "$kbase/healthz")" = 200 ]'
echo "ok Keeper starts alongside CPA"
keeper_login
expect 200 -b "$JAR" "$kbase/api/v1/status"
echo "ok Keeper serves an authenticated management-backed status"
version=$(curl -s -b "$JAR" "$kbase/api/v1/version")
echo "$version" | grep -q "$KEEPER_VERSION" || fail "Keeper version is not $KEEPER_VERSION: $version"
echo "ok Keeper is $KEEPER_VERSION"

for _ in $(seq 1 90); do
  [ "$(keeper_keys)" -gt 0 ] && break
  sleep 1
done
[ "$(keeper_keys)" -gt 0 ] || fail "Litestream wrote no keeper/ keys to the bucket"
echo "ok Litestream replicates Keeper's database to object storage"

start_cpa
wait_for '[ "$(status "$kbase/healthz")" = 200 ]'
keeper_login
expect 200 -b "$JAR" "$kbase/api/v1/status"
[ "$(keeper_keys)" -gt 0 ] || fail "keeper/ keys are gone after the restart"
echo "ok Keeper and its replicated history survive a container restart"
