# CF-1: CPA + Keeper + Litestream in one image (K1 co-located default).
#
# - CPA is built from our public fork TogetherWeOwn/CLIProxyAPI branch
#   tog/v8.0.23-tog.1 (5 tog patches on upstream v8.0.23).
# - Keeper (Willxup/cpa-usage-keeper) is built from pinned upstream source so
#   the image carries no prebuilt binaries; it talks to CPA over loopback.
# - Litestream replicates Keeper's SQLite (/data/app.db) to object storage
#   through the same S3-compatible endpoint CPA itself uses (the Worker's S3
#   shim over R2 in production), so no extra credentials are needed.
# All three pins are commit SHAs: CPA_COMMIT, KEEPER_COMMIT, LITESTREAM_COMMIT.

FROM golang:1.26-bookworm AS cpa-builder
ARG CPA_VERSION=v8.0.23-tog.1
ARG CPA_COMMIT=0d7a0b09d39f4ba91c4160d83ff524eb80cb907e
WORKDIR /src
RUN git init -q . && git remote add origin https://github.com/TogetherWeOwn/CLIProxyAPI.git \
  && git fetch -q --depth 1 origin "${CPA_COMMIT}" && git checkout -q FETCH_HEAD
RUN CGO_ENABLED=1 GOOS=linux go build -buildvcs=false \
  -ldflags="-s -w -X 'main.Version=${CPA_VERSION}' -X 'main.Commit=${CPA_COMMIT}'" \
  -o /out/CLIProxyAPI ./cmd/server/

# Node only provides the toolchain for Keeper's web UI build; nothing from
# here lands in the final image.
FROM node:24-bookworm-slim AS node-source

FROM golang:1.26-bookworm AS keeper-builder
ARG KEEPER_VERSION=v1.15.11
ARG KEEPER_COMMIT=71a41cc2d1cce8d75b42473adf31f2616ad8085e
COPY --from=node-source /usr/local /usr/local
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /keeper
RUN git init -q . && git remote add origin https://github.com/Willxup/cpa-usage-keeper.git \
  && git fetch -q --depth 1 origin "${KEEPER_COMMIT}" && git checkout -q FETCH_HEAD
WORKDIR /keeper/web
RUN npm ci && npm run build
WORKDIR /keeper
RUN CGO_ENABLED=1 GOOS=linux go build -buildvcs=false \
  -ldflags="-s -w -X 'cpa-usage-keeper/internal/version.Version=${KEEPER_VERSION}'" \
  -o /out/cpa-usage-keeper ./cmd/server/main.go

FROM golang:1.26-bookworm AS litestream-builder
ARG LITESTREAM_VERSION=v0.5.17
ARG LITESTREAM_COMMIT=ccd326c175b583b5e82893a6078f06dcef5fba3f
WORKDIR /litestream
RUN git init -q . && git remote add origin https://github.com/benbjohnson/litestream.git \
  && git fetch -q --depth 1 origin "${LITESTREAM_COMMIT}" && git checkout -q FETCH_HEAD
# Litestream uses a pure-Go SQLite port, so the binary is static.
RUN CGO_ENABLED=0 GOOS=linux go build -buildvcs=false \
  -ldflags="-s -w" \
  -o /out/litestream ./cmd/litestream

FROM debian:bookworm-slim
# Panel pairing for CPA v8.0.23 (CF-1): management-center v1.26.1, released
# 2026-10-10, one day after upstream v8.0.23 (2026-10-09). SHA256 pinned.
ARG PANEL_VERSION=v1.26.1
ARG PANEL_SHA256=32d835ee74ac9241e3b975567a1d6c24a64627931679dc616721fe5271dfca33
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
  && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /panel /data /keeper \
  && curl -fsSL --retry 5 --retry-all-errors -o /panel/management.html \
    "https://github.com/router-for-me/Cli-Proxy-API-Management-Center/releases/download/${PANEL_VERSION}/management.html" \
  && echo "${PANEL_SHA256}  /panel/management.html" | sha256sum -c -
WORKDIR /CLIProxyAPI
COPY --from=cpa-builder /out/CLIProxyAPI ./CLIProxyAPI
COPY --from=keeper-builder /out/cpa-usage-keeper /keeper/cpa-usage-keeper
COPY --from=litestream-builder /out/litestream /usr/local/bin/litestream
COPY entrypoint.sh /entrypoint.sh
ENV MANAGEMENT_STATIC_PATH=/panel/management.html
EXPOSE 8317 8080
ENTRYPOINT ["/entrypoint.sh"]
