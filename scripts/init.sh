#!/usr/bin/env bash
# Creates the Mosquitto password file and ACL with the `admin` account.
# Run once, before `docker compose up -d`. Safe to run again (does nothing).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Missing .env (cp .env.example .env, then edit it)" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MQTT_ADMIN_PASSWORD:?MQTT_ADMIN_PASSWORD is empty in .env}"

mkdir -p mosquitto/config certs

if [ -f mosquitto/config/passwd ]; then
  echo "Already initialised (mosquitto/config/passwd exists)."
  exit 0
fi

# Runs as root inside a throw-away container so that the files can be handed
# to the `mosquitto` user (uid 1883) without needing sudo on the host.
docker run --rm --user root \
  -e ADMIN_PW="$MQTT_ADMIN_PASSWORD" \
  -v "$PWD/mosquitto/config:/cfg" \
  --entrypoint sh eclipse-mosquitto:2 -c '
    set -e
    mosquitto_passwd -c -b /cfg/passwd admin "$ADMIN_PW"
    {
      echo "# BEGIN admin"
      echo "user admin"
      echo "topic readwrite ocam/#"
      echo "# END admin"
    } > /cfg/acl
    chown 1883:1883 /cfg/passwd /cfg/acl
    chmod 640 /cfg/passwd /cfg/acl
  '

echo "Created mosquitto/config/passwd and mosquitto/config/acl (account: admin)."
echo "Next: put fullchain.pem and privkey.pem in ./certs, then: docker compose up -d"
