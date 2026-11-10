#!/usr/bin/env bash
# Manages MQTT accounts and their ACL blocks (MQTT_PROTOCOL.md, appendix A).
#
#   ./scripts/user.sh add <name> <camera|viewer|phone>   # asks for the password
#   ./scripts/user.sh remove <name>
#
# Roles:
#   camera  an agent (Go / C) or a phone that only acts as a camera
#   viewer  a viewer only
#   phone   the Flutter app: camera and viewer with the same account
#
# `<name>` is the MQTT user name and the device / client id used in the topics.
set -euo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$self")/.."

action="${1:-}"
name="${2:-}"
role="${3:-}"

usage() { sed -n '2,13p' "$self" | sed 's/^# \{0,1\}//' >&2; exit 1; }

[ -n "$action" ] && [ -n "$name" ] || usage
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid name (letters, digits, - and _ only)." >&2; exit 1; }
[ "$name" != "admin" ] || { echo "'admin' is managed by init.sh." >&2; exit 1; }
[ -f mosquitto/config/passwd ] || { echo "Run ./scripts/init.sh first." >&2; exit 1; }

password=""
case "$action" in
  add)
    case "$role" in camera|viewer|phone) ;; *) usage ;; esac
    read -r -s -p "Password for $name: " password; echo
    [ -n "$password" ] || { echo "Empty password." >&2; exit 1; }
    ;;
  remove) ;;
  *) usage ;;
esac

docker run --rm --user root -i \
  -e NAME="$name" -e ROLE="$role" -e ACTION="$action" -e PW="$password" \
  -v "$PWD/mosquitto/config:/cfg" \
  --entrypoint sh eclipse-mosquitto:2 -s <<'EOF'
set -e
if [ "$ACTION" = "add" ]; then
  if grep -qx "# BEGIN $NAME" /cfg/acl; then
    echo "User $NAME already exists (remove it first)." >&2
    exit 1
  fi
  mosquitto_passwd -b /cfg/passwd "$NAME" "$PW"
  {
    echo "# BEGIN $NAME"
    echo "user $NAME"
    # camera part: publishes its state, receives offers, answers viewers
    case "$ROLE" in camera|phone)
      echo "topic write ocam/dev/$NAME/state"
      echo "topic read  ocam/dev/$NAME/in/#"
      echo "topic write ocam/cli/+/in/$NAME"
      ;;
    esac
    # viewer part: sees all the cameras, calls them
    case "$ROLE" in viewer|phone)
      echo "topic read  ocam/dev/+/state"
      echo "topic read  ocam/cli/$NAME/in/#"
      echo "topic write ocam/dev/+/in/$NAME"
      ;;
    esac
    # ICE config: read by everyone (cameras need it for TURN too)
    echo "topic read  ocam/config/ice"
    echo "# END $NAME"
  } >> /cfg/acl
  echo "User $NAME added ($ROLE)."
else
  mosquitto_passwd -D /cfg/passwd "$NAME" || true
  sed -i "/^# BEGIN $NAME\$/,/^# END $NAME\$/d" /cfg/acl
  echo "User $NAME removed."
fi
chown 1883:1883 /cfg/passwd /cfg/acl
chmod 640 /cfg/passwd /cfg/acl
EOF

# Reload the broker if it is running (passwd and ACL are re-read on SIGHUP).
if docker compose ps --status running --services 2>/dev/null | grep -qx mosquitto; then
  docker compose kill -s HUP mosquitto
  echo "Broker reloaded."
fi
