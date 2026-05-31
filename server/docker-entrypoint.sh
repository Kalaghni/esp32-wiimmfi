#!/bin/sh
# Render config.xml from the template using environment variables, then launch
# the server. wfc-server reads ./config.xml (and game_list.tsv, motd.txt, and a
# writable ./state dir) from its working directory.
set -e

: "${BIND_ADDRESS:=0.0.0.0}"
: "${DB_ADDRESS:=127.0.0.1}"
: "${DB_USER:?DB_USER is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${API_SECRET:?API_SECRET is required}"
export BIND_ADDRESS DB_ADDRESS DB_USER DB_PASSWORD API_SECRET

envsubst < config.xml.tmpl > config.xml

mkdir -p state

exec ./wwfc "$@"
