#!/bin/sh
# Publishes the ICE configuration (STUN + TURN with temporary credentials) as a
# retained message on ocam/config/ice, once a day. The credentials are valid
# 30 days, so a copy always has at least 29 days left and a leaked one expires
# by itself. See STUN_TURN.md and MQTT_PROTOCOL.md section 5.
set -eu

: "${MQTT_HOST:?MQTT_HOST is required}"
: "${MQTT_ADMIN_PASSWORD:?MQTT_ADMIN_PASSWORD is required}"
: "${TURN_HOST:?TURN_HOST is required}"
: "${TURN_SECRET:?TURN_SECRET is required}"

MQTT_PORT="${MQTT_PORT:-8883}"
TTL="${CREDENTIAL_TTL:-2592000}"   # 30 days
INTERVAL="${PUBLISH_INTERVAL:-86400}" # 1 day
RETRY="${RETRY_INTERVAL:-30}"

# Public CA (Let's Encrypt) by default; a self-signed CA can be given.
CAFILE="${MQTT_CAFILE:-/etc/ssl/certs/ca-certificates.crt}"

while true; do
  now=$(date +%s)
  exp=$((now + TTL))
  username="$exp:ocam"
  credential=$(printf '%s' "$username" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)

  payload=$(printf '{"v":1,"ts":%s,"stun":["stun:%s:3478"],"turn":{"urls":["turn:%s:3478?transport=udp","turns:%s:5349?transport=tcp"],"username":"%s","credential":"%s","expires":%s}}' \
    "$now" "$TURN_HOST" "$TURN_HOST" "$TURN_HOST" "$username" "$credential" "$exp")

  if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" --cafile "$CAFILE" \
       -i admin-ice -u admin -P "$MQTT_ADMIN_PASSWORD" \
       -t ocam/config/ice -r -q 1 -m "$payload"; then
    echo "[ice-publisher] published ocam/config/ice (expires $exp)"
    sleep "$INTERVAL"
  else
    echo "[ice-publisher] publish failed, retrying in ${RETRY}s" >&2
    sleep "$RETRY"
  fi
done
