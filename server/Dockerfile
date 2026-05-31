# Multi-stage build of WiiLink24/wfc-server (vendored in this directory).
#
# Pin the Go version to the toolchain the upstream go.mod expects. Bump this
# together with `git subtree pull` if upstream raises its go directive.
ARG GO_VERSION=1.24

# ---- build stage ----
FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src

# Cache module downloads first.
COPY go.mod go.sum ./
RUN go mod download

# Build a static binary (pgx and the other deps are pure Go, so CGO is off).
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/wwfc .

# ---- runtime stage ----
FROM alpine:3.20
WORKDIR /app

# gettext -> envsubst (config templating); ca-certificates for outbound TLS.
RUN apk add --no-cache gettext ca-certificates

# The binary plus the data files it reads from its working directory.
COPY --from=build /out/wwfc ./wwfc
COPY game_list.tsv ./game_list.tsv
COPY motd.txt ./motd.txt
COPY config.xml.tmpl ./config.xml.tmpl
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh && mkdir -p state

ENTRYPOINT ["./docker-entrypoint.sh"]
