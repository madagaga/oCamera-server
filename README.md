# oCamera server: Mosquitto + STUN / TURN (Docker)

A `docker compose` stack with everything the cameras and viewers need on the server side:

| Service | Role | Ports |
|---|---|---|
| `mosquitto` | MQTT 3.1.1 signaling over TLS, login / password, role-based ACL ([MQTT_PROTOCOL.md](docs/MQTT_PROTOCOL.md), appendix A) | 8883/tcp |
| `coturn` | STUN + TURN (temporary credentials), see [STUN_TURN.md](docs/STUN_TURN.md) | 3478 udp+tcp, 5349 tcp (TLS), 49152-49252 udp |
| `ice-publisher` | Publishes the TURN credentials on `ocam/config/ice` (retained) every day. Viewers **and camera phones** read it | n/a |

Target: a **Linux** server with a public IP. `coturn` uses the host network (`network_mode: host`), so it does
not work on Docker Desktop (Windows / macOS), except for syntax checks.

## Requirements

- Docker and Docker Compose v2.
- Two DNS names pointing to the server (they can be the same): `MQTT_HOST` and `TURN_HOST`.
- A valid TLS certificate for these names (Let's Encrypt for instance), copied to `./certs/`:
  - `certs/fullchain.pem`
  - `certs/privkey.pem`
- Firewall open: 8883/tcp, 3478/udp+tcp, 5349/tcp, 49152-49252/udp.

## Getting started

```bash
cp .env.example .env          # then edit: DNS names, public IP, secrets
openssl rand -hex 32          # paste the result into TURN_SECRET

./scripts/init.sh             # creates the admin account and the ACL
docker compose up -d --build
docker compose logs -f
```

The scripts are bash (`bash scripts/init.sh` if the executable bit is missing).

### Certificate permissions

Mosquitto (uid 1883) and coturn read the files in `./certs`. With Let's Encrypt, a certbot *deploy hook* that
copies the files and makes them readable is enough, for example:

```bash
cp /etc/letsencrypt/live/$DOMAIN/{fullchain,privkey}.pem ./certs/
chmod 644 ./certs/fullchain.pem
chmod 640 ./certs/privkey.pem && chown root:1883 ./certs/privkey.pem
docker compose restart mosquitto coturn   # after every renewal
```

If coturn cannot read the key (different user), it disables TLS: check its logs.

## MQTT accounts

```bash
./scripts/user.sh add cam-entrance camera   # Go / C agent, or a phone used only as a camera
./scripts/user.sh add alice viewer          # viewer only
./scripts/user.sh add garden-phone phone    # the Flutter app: camera + viewer with the same account
./scripts/user.sh remove alice
```

The script writes the (hashed) password and the account's ACL block, then reloads Mosquitto. Every block also grants
**read access to `ocam/config/ice`**: a phone in camera mode needs it to receive the TURN server
(see the [protocol](docs/MQTT_PROTOCOL.md), section 5).

A reload does not disconnect a client that is already connected: after a `remove`, restart Mosquitto
(`docker compose restart mosquitto`) to cut the running session.

## Verification

```bash
# ICE published? (must return the JSON with stun / turn)
docker compose exec mosquitto mosquitto_sub -h localhost -p 8883 \
  --cafile /mosquitto/certs/fullchain.pem -u admin -P "$MQTT_ADMIN_PASSWORD" -t ocam/config/ice -C 1
```

The ACL checks of appendix A of the protocol (alice writing under another name, a camera reading the others, etc.)
must be repeated after every change.

- STUN: `turnutils_stunclient $TURN_HOST` returns the public address of the caller.
- TURN: in the app, the badge of the live view shows `Relayed` when the relay is used. App logs:
  `[MQTT] : ICE config 2 server entries` on the viewer **and** on the camera.
- Test from a viewer on 4G/5G, with and without TURN.

## Self-signed certificate (local network, tests)

Put `fullchain.pem`, `privkey.pem` and the CA (`ca.crt`) in `./certs`, then set `MQTT_CAFILE=/certs/ca.crt`
in `.env` for the publisher. The apps validate the certificate: the CA must be installed on the phones.

## Notes

- `--denied-peer-ip`: coturn refuses to relay towards private networks. If the server is on **the same local
  network** as the cameras, adjust these lines in `docker-compose.yml`.
- If the server is behind a NAT, put `PUBLIC_IP/PRIVATE_IP` in `EXTERNAL_IP` and forward the ports above.
- The TURN credentials last 30 days and are republished every day: nothing to renew by hand.
- `mosquitto/config/` (passwords, ACL), `certs/` and `.env` are never versioned (`.gitignore`).
