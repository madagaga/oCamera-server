# STUN / TURN: deployment with coturn (optional)

**Everything here is optional.** With nothing installed or configured, the clients use Google's public STUN:
it is a STUN **without a password** (Google does not offer a public TURN). That is enough as long as
direct connections succeed.

coturn does **both STUN and TURN**: a single service if you decide to host your own.

The `docker-compose.yml` of this repository runs coturn and publishes the credentials for you (see the
[README](../README.md)); this document explains the choices behind it.

## Three levels

| Level | What you install | Credentials | When |
|---|---|---|---|
| **0: default** | Nothing | None | To start; viewers on 4G/5G succeed |
| **1: your own STUN** | coturn (STUN only, no account) | None | Stop depending on Google |
| **2: STUN + TURN** | coturn with relay | **Temporary credentials, published over MQTT** (see below) | A mobile viewer fails to connect directly (symmetric NAT / CGNAT) |

The MQTT message `ocam/config/ice` (`MQTT_PROTOCOL.md`, section 5) is **optional** and its `username` /
`credential` are optional too: a STUN-only server, or a server without authentication, is described without them.

## Who needs what

| Component | STUN | TURN |
|---|---|---|
| Camera agent (Go / C) | yes, **configurable** URL (`ice.stun`, default Google) | **no** (the agent sends to the viewer's relay address like to any other candidate) |
| Phone in camera mode | yes | yes, if configured (`ocam/config/ice`) |
| Flutter viewer | yes | yes, if configured |

On the viewer side, the priority is: settings typed by hand > `ocam/config/ice` message > default Google STUN.

## Level 1: STUN only (no account)

coturn's STUN is open (it relays nothing). A minimal configuration file:

```
listening-port=3478
external-ip=PUBLIC_IP
fingerprint
no-tcp-relay        # no TURN: no relay resources
```
Firewall: UDP 3478 (and TCP 3478). No credentials to create.

## Level 2: STUN + TURN with temporary credentials

There is no list of accounts in coturn: a **shared secret** is used to compute time-limited credentials.
There is therefore **nothing to duplicate with Mosquitto**: removing a user only touches Mosquitto.

`/etc/turnserver.conf`:
```
listening-port=3478
tls-listening-port=5349
external-ip=PUBLIC_IP            # or PUBLIC_IP/PRIVATE_IP if the server is behind a NAT
realm=turn.example.com
fingerprint

use-auth-secret
static-auth-secret=LONG_GENERATED_SECRET

min-port=49152
max-port=49252

cert=/etc/coturn/certs/fullchain.pem
pkey=/etc/coturn/certs/privkey.pem

user-quota=4
total-quota=50
no-multicast-peers
no-cli

# do not relay towards private networks (protects the server's network)
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
```
- `denied-peer-ip`: if coturn is on **the same local network** as the cameras, adjust or remove these lines.
- The `use-auth-secret` / `static-auth-secret` combination should be validated on your coturn version
  with `turnutils_uclient` (see "Verification").

### Publishing the credentials over MQTT

A script run **once a day** (cron) computes the credentials (valid 30 days) and publishes them as retained:
at least 29 days always remain, and a leaked copy expires by itself. In this repository the `ice-publisher`
service does exactly this.

`/usr/local/bin/ocam-publish-ice`:
```bash
#!/bin/sh
# Variables: SECRET = coturn's static-auth-secret; admin password in a chmod 600 file
SECRET='LONG_GENERATED_SECRET'
HOST='turn.example.com'
BROKER='mqtt.example.com'
NOW=$(date +%s)
EXP=$((NOW + 30*24*3600))
USERNAME="$EXP:ocam"
CRED=$(printf '%s' "$USERNAME" | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)

mosquitto_pub -h "$BROKER" -p 8883 --cafile /etc/mosquitto/certs/ca.crt \
  -u admin -P "$(cat /etc/mosquitto/admin.pass)" \
  -t ocam/config/ice -r -q 1 -m \
  "{\"v\":1,\"ts\":$NOW,\"stun\":[\"stun:$HOST:3478\"],\"turn\":{\"urls\":[\"turn:$HOST:3478?transport=udp\",\"turns:$HOST:5349?transport=tcp\"],\"username\":\"$USERNAME\",\"credential\":\"$CRED\",\"expires\":$EXP}}"
```
```
0 4 * * * /usr/local/bin/ocam-publish-ice
```

For a **STUN only** setup (level 1), the same script publishes without the `turn` block (or publish the JSON by hand once).

## Firewall ports to open

| Port | Protocol | Use | Level |
|---|---|---|---|
| 3478 | UDP and TCP | STUN / TURN | 1 and 2 |
| 5349 | TCP (and UDP) | TURN over TLS (crosses restrictive networks) | 2 |
| 49152-49252 | UDP | Media relay | 2 |

## Client configuration

**Agent** (one optional parameter):
```yaml
ice:
  stun: "stun:turn.example.com:3478"   # default if absent: Google public STUN
```

**Viewer and camera phone**: nothing to enter if `ocam/config/ice` is published. Otherwise, Google STUN by default.

## Verification
- STUN: `turnutils_stunclient turn.example.com` must return the public address of the calling machine.
- TURN: generate a temporary pair with the script above, then
  `turnutils_uclient -u "<username>" -w "<credential>" turn.example.com` must complete an allocation.
- Reading the config: `mosquitto_sub -t ocam/config/ice -C 1 ...` must return the retained message.
- In real use: the viewer's `getStats()` diagnostic screen must show the selected candidate type.
  `relay` = the TURN is used; `srflx` or `host` = direct connection.
- Test from a viewer on 4G/5G, with several carriers if possible, **with** and **without** TURN.
