# MQTT Signaling Protocol — version 1

This document fully replaces the old protocol (kept in `MQTT_PROTOCOL_legacy.md`, with no
compatibility layer: the old and new protocols do not coexist).

MQTT is used **only for WebRTC signaling** (SDP, ICE), device presence and small commands.
Video and audio travel peer-to-peer over WebRTC, without going through the broker.

```
 Viewer (Flutter)            Mosquitto broker              Camera (Go / C agent, or phone)
       |                           |                                |
       |-- SUBSCRIBE dev/+/state ->|<-- PUBLISH dev/{id}/state -----|  (retained + Last Will)
       |-- offer ----------------->|------------------------------->|
       |<------------------------------------------------ answer ---|
       |<========================= WebRTC P2P (video/audio) ========>|
```

## 1. Assumptions and scope

- **MQTT 3.1.1**, TLS, **username / password** authentication (client certificates are a planned
  evolution, see appendix C).
- **One MQTT server = one circle of trust**: any viewer can call any camera on the server.
  There is no notion of tenant in the topics.
- **Mosquitto broker with per-role ACL** (appendix A). The identity and confinement guarantees
  described here **only hold if the ACL is in place** (section 9). The protocol works without it, but
  with no security guarantee.
- **Reliable clock (NTP)** on all devices.
- Only one simultaneous session per camera.
- Out of scope: web viewer, multiple simultaneous viewers, application-level message encryption.
- STUN / TURN servers: **optional**. With no configuration at all, clients use a public STUN
  without credentials (section 5).

## 2. Identities and roles

- A device's **identifier** is its **MQTT username**, and the MQTT `clientId` is equal to it
  (`use_username_as_clientid true`). One account per device, one account per viewer user.
- Format: `[A-Za-z0-9_-]`, 3 to 32 characters (never `/`, `+`, `#`). Examples: `cam-entree`, `cli-alice`.
- Two roles, defined by the broker ACL:
  - **camera**: RTSP -> WebRTC agent, or phone in camera mode (it then uses a *camera* account,
    distinct from the user's viewer account);
  - **viewer**: application that watches the cameras.
- The identifier is **never derived** from sensitive data (no more MD5 of the RTSP URL).

## 3. Topics

| Topic | Content | QoS | Retained | Written by |
|---|---|---|---|---|
| `ocam/dev/{devId}/state` | Camera state (section 5) | 1 | **yes** (+ Last Will) | `devId` only |
| `ocam/dev/{devId}/in/{fromId}` | Messages **to** a camera | 1 | no | `fromId` (a viewer) |
| `ocam/cli/{cliId}/in/{fromId}` | Messages **to** a viewer | 1 | no | `fromId` (a camera) |
| `ocam/config/ice` | ICE configuration (STUN / TURN), **optional** (section 5) | 1 | **yes** | `admin` only |

- **The sender is the last level of the topic** (`fromId`). There is no `from` field in the
  payload: the ACL guarantees that `fromId` is the sender's username.
- Subscriptions:
  - camera: `ocam/dev/{self}/in/#` and `ocam/config/ice` (optional; the phone camera uses it for its TURN)
  - viewer: `ocam/dev/+/state`, `ocam/cli/{self}/in/#` and `ocam/config/ice` (optional)
- No broadcast topic, no `query`: each camera's retained state is received on subscription.

### Connection parameters

| Parameter | Value |
|---|---|
| Version | MQTT 3.1.1 |
| CleanSession | `true` (agent and viewer) |
| KeepAlive | 30 s |
| Automatic reconnection | yes, with re-subscription and republication of `state` |
| TLS | yes, broker certificate **validated** (no `InsecureSkipVerify`) |
| Last Will (camera) | `state` topic, QoS 1, retained, payload = state with `online:false, busy:false` |
| Max payload size | 32 KB; an SDP offer is 6 to 10 KB, embedded buffers must be **>= 16 KB** |

## 4. Envelope of `in` messages

```json
{ "v": 1, "ts": 1760000000, "sid": "k3f9x2m1q8", "type": "offer", "data": { } }
```

| Field | Type | Description |
|---|---|---|
| `v` | integer | Protocol version (`1`). A message with a higher `v` is ignored. |
| `ts` | integer | Unix seconds UTC at send time. The receiver **ignores** messages where `|now - ts| > 30 s`. |
| `sid` | string | Session identifier (8 to 32 characters, random), **chosen by the viewer** at the offer. Absent for `cmd` / `res`. |
| `type` | string | `offer`, `answer`, `ice`, `bye`, `error`, `cmd`, `res` |
| `data` | object | Type-specific content |

General rules:
- Unknown fields and unknown types are **ignored** (logged), never a source of error.
- Valid JSON only; every text value must be **escaped** by a real serializer
  (never built by concatenation).
- A camera whose clock is not yet synchronized (year < 2024) skips the `ts` check
  until the first synchronization.
- A message ignored because `ts` is out of tolerance is reported in the logs. Only an
  `offer` gets an `error` (`stale`) in return.

## 5. Camera state (`state`)

Published on connection, on every change, and sent automatically by the broker (Last Will)
on disconnection. **Retained**.

```json
{
  "v": 1,
  "ts": 1760000000,
  "name": "Entrée",
  "online": true,
  "busy": false,
  "viewer": null,
  "kind": "relay",
  "caps": {
    "video": ["h264"],
    "audio": ["pcmu"],
    "streams": ["main", "sub"],
    "cmds": ["flip", "torch"]
  },
  "agent": { "name": "ocamera-go", "version": "1.0.0" }
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string (<= 64) | Display name |
| `online` | boolean | `false` in the Last Will |
| `busy` | boolean | A session is active (replaces the old `streaming`) |
| `viewer` | string or `null` | Identifier of the viewer of the current session |
| `kind` | string | `relay` (RTSP agent) or `phone` (phone camera), informational |
| `caps` | object (optional) | Capabilities: `video`, `audio` (lowercase codecs), `streams`, `cmds`. If absent, the viewer keeps the last known capabilities. |
| `agent` | object (optional) | Implementation and version, informational |
| `facing` | string (optional) | Camera used by a phone during a session: `back` (rear) or `front`. Absent outside a session or if the camera does not know; the viewer displays nothing in that case. Republished after every successful `flip`. |
| `battery` | object (optional) | Battery of a device that has one (phone camera): `level` (integer 0 to 100) and `charging` (boolean, `true` if external power is connected, even with a full battery). Absent for a mains-powered camera; the viewer displays nothing in that case. Republished when the charging state changes, when the level changes by at least 5 points, or on every change below 20%, at most every 5 minutes. |

- The **Last Will** contains the full state with `online:false` and `busy:false` (the name is known at connection time).
- **Removing a device**: the administrator publishes an **empty** retained message on its `state`
  (`mosquitto_pub -r -n`). A viewer that receives an empty payload on a `state` removes the device from its list.
- Viewers **do not announce** their presence.

### ICE configuration (optional)

A **retained** message that the administrator publishes on `ocam/config/ice` so that viewers
do not have to enter STUN / TURN servers. It is readable by **viewers** and by the **cameras** that need
it (the phone in camera mode, which is a full WebRTC peer; an agent such as the Go agent only needs a STUN,
configured locally).

```json
{
  "v": 1,
  "ts": 1760000000,
  "stun": ["stun:turn.example.com:3478"],
  "turn": {
    "urls": ["turn:turn.example.com:3478?transport=udp", "turns:turn.example.com:5349?transport=tcp"],
    "username": "1762592000:ocam",
    "credential": "base64...",
    "expires": 1762592000
  }
}
```

| Field | Description |
|---|---|
| `stun` | (optional) List of STUN URLs. A STUN has no credentials. |
| `turn` | (optional) A TURN server. |
| `turn.username`, `turn.credential` | (**optional**) Omit for a server without authentication. |
| `turn.expires` | (optional) Credential expiry, Unix seconds; informational. |

Priority order on the viewer side to build its `iceServers`:
1. settings entered manually in the application (if any);
2. otherwise the `ocam/config/ice` message (if it exists and is valid);
3. otherwise the **default public STUN**, without credentials (`stun:stun.l.google.com:19302`,
   `stun1.l.google.com:19302`).

The message is entirely optional: a broker without this topic works normally. A missing,
empty or invalid message is ignored. The viewer re-reads the retained value on every MQTT connection.

## 6. Messages

All are published on `ocam/dev/{devId}/in/{fromId}` (to a camera) or
`ocam/cli/{cliId}/in/{fromId}` (to a viewer), with the envelope from section 4.

### `offer` — viewer -> camera
```json
{ "v":1, "ts":1760000000, "sid":"k3f9x2m1q8", "type":"offer",
  "data": { "sdp": "v=0\r\no=- ...", "want": { "stream": "sub", "audio": true } } }
```
| `data` | Description |
|---|---|
| `sdp` | SDP offer (the viewer receives: `recvonly` video and audio) |
| `want.stream` | (optional) Requested stream among `caps.streams`; default: the first one |
| `want.audio` | (optional) `false` to not receive audio |

### `answer` — camera -> viewer
```json
{ "v":1, "ts":1760000001, "sid":"k3f9x2m1q8", "type":"answer", "data": { "sdp": "v=0\r\n..." } }
```

### `ice` — in both directions
```json
{ "v":1, "ts":1760000002, "sid":"k3f9x2m1q8", "type":"ice",
  "data": { "candidates": [ { "candidate":"candidate:1 1 UDP 2113937151 192.168.1.10 54321 typ host",
                              "sdpMid":"0", "sdpMLineIndex":0 } ], "end": false } }
```
| `data` | Description |
|---|---|
| `candidates` | One or more candidates. `sdpMid` and `sdpMLineIndex` may be `null` (no exception when reading). |
| `end` | `true` after the last candidate (list possibly empty) |

- Senders **batch** candidates (window of about 100 ms) rather than sending one message per candidate.
- Receivers accept **trickle** (candidates after the `offer` / `answer`) as well as **non-trickle**
  (candidates already in the SDP, no `ice` sent).

### `bye` — end of session, in both directions
```json
{ "v":1, "ts":1760000300, "sid":"k3f9x2m1q8", "type":"bye", "data": { "reason": "user" } }
```
`reason` (optional): `user`, `timeout`, `ice_failed`, `source_lost`, `shutdown`.

### `error` — camera -> viewer
```json
{ "v":1, "ts":1760000001, "sid":"k3f9x2m1q8", "type":"error",
  "data": { "code": "busy", "message": "session already active", "retryable": true } }
```
| `code` | Meaning |
|---|---|
| `busy` | A session is already active |
| `bad_request` | Invalid message or SDP, requested stream does not exist |
| `unsupported_codec` | No common codec |
| `source_unavailable` | Source stream (RTSP) unreachable |
| `stale` | `ts` out of tolerance (probable clock problem) |
| `internal` | Other camera-side error |

An `error` **terminates** the session: it is never followed by a `bye`.

### `cmd` / `res` — commands (outside a session)
```json
{ "v":1, "ts":1760000400, "type":"cmd", "data": { "id":"c-17", "name":"torch", "args": { "on": true } } }
{ "v":1, "ts":1760000401, "type":"res", "data": { "id":"c-17", "ok": true } }
{ "v":1, "ts":1760000401, "type":"res", "data": { "id":"c-18", "ok": false,
                                                 "error": { "code":"unsupported", "message":"..." } } }
```
- No `sid`. The command is identified by `data.id`; the `res` is published to the viewer's inbox.
- The available commands are listed in `caps.cmds`. Standard names: `flip` (switch a phone's
  camera), `torch` (`args.on`), `video` and `audio` (`args.on` boolean: mutes or restores
  sending of the current session's video or sound; reserved for the viewer of that session, otherwise
  `ok:false` / `unavailable`; with no matching track, muting answers `ok:true` and restoring
  `unavailable`). The track is only disabled (`enabled=false`): the session and the capture
  stay open, the picture goes black and the bitrate drops, and resuming is immediate. Implementation-specific names: `x-` prefix.
- An unknown command gets a `res` with `ok:false` and the code `unsupported`.
- Expected response time: 10 s.
- The old `flipCamera` / `toggleCamera` are removed, replaced by `cmd` `flip`.

## 7. Session rules (camera side)

The camera is in one of two states: `idle` or `busy(sid, viewer)`.

| Event | In `idle` | In `busy` |
|---|---|---|
| valid `offer` | creates the session, replies `answer`, moves to `busy`, republishes `state` (`busy:true`, `viewer`) | same `sid` **and** same viewer: **duplicate**, resends the same `answer` (or ignores); otherwise `error busy` to the sending viewer, **active session unchanged** |
| invalid `offer` | `error` (`bad_request`, `unsupported_codec`, `source_unavailable`, `stale`), stays `idle` | `error busy` |
| `ice` | ignored | accepted **only** if `sid` and viewer match the session |
| `bye` | ignored | accepted **only** if `sid` and viewer match; closes the session |
| `cmd` | handled | handled |

End of session:
- `bye` from the viewer;
- failure or loss of the WebRTC connection (state `failed`, or `disconnected` > 10 s): the camera sends
  `bye` (`reason: ice_failed`);
- no connection established within **30 s** after the `answer`: `bye` (`reason: timeout`);
- RTSP source lost after reconnection attempts: `bye` (`reason: source_lost`).

After the end: closing of the PeerConnection and the RTSP stream, republication of `state`
(`busy:false`, `viewer:null`).

Other rules:
- **Loss of the MQTT connection does not cut** an already established WebRTC session (signaling
  is no longer needed). On reconnection, the camera republishes its exact `state`.
- The **viewer** ignores any message whose `sid` is not that of its current call.
- The **viewer** sends `bye` at the end of a call; if it disappears without doing so, the camera detects it
  through the expiry of the WebRTC connection.
- The RTSP stream is opened **after** the WebRTC connection is established (unchanged).
- **Session log** (mandatory on the camera side): start (`sid`, viewer), end (reason, duration).

## 8. Flows

### Nominal call
```
Viewer                       Broker                       Camera
  |-- offer (sid=S) ---------->|-- ocam/dev/cam/in/cli --->|
  |                            |                           | creates the PeerConnection
  |<-- answer (sid=S) ---------|<-- ocam/cli/cli/in/cam ---|  state: busy=true, viewer=cli
  |<-- ice (sid=S) ------------|<--------------------------|  (candidates in batches)
  |-- ice (sid=S) ------------>|-------------------------->|
  |========= WebRTC connection established: the camera opens the RTSP =========|
  |-- bye (sid=S) ------------>|-------------------------->|  state: busy=false
```

### Busy camera (second viewer)
```
Viewer B                                                   Camera (busy with A)
  |-- offer (sid=T) ------------------------------------------>|
  |<-- error (sid=T, code=busy) --------------------------------|   A's session is unchanged
```

### Camera power loss
```
Camera ---X (no more keepalive)
Broker: publishes the Last Will  ->  state { online:false, busy:false }   (retained)
Viewers: show the camera as offline
```

## 9. Security

- **Authentication**: MQTT username / password, TLS mandatory with **validated broker certificate**.
- **Authorization**: Mosquitto **per-role** ACL (appendix A). It guarantees that:
  - a client only writes to an inbox under its own name (reliable `fromId`);
  - a client only reads its own inbox;
  - a camera only writes its own `state`, does not read other cameras and calls no one;
  - a viewer never publishes a camera state.
- **What the ACL does not cover**: a stolen *viewer* account gives access to all cameras on the server
  until it is revoked (the "one server = one circle of trust" model). Countermeasures: one account per
  viewer (revocable), long generated passwords, session log, detection by ejection
  (two connections with the same account -> the first one is ejected).
- **ACL self-test** (camera agent, recommended): at startup, the agent tries to subscribe to
  `ocam/dev/+/state` (forbidden for a camera). If the broker **accepts** the subscription, the agent logs
  a visible warning ("permissive broker: the ACL is not enforced") and starts anyway.
- Passwords **never** appear in the logs.
- The broker is the root of trust: the SDP's DTLS fingerprint goes through it.

## Appendix A — Mosquitto configuration (username / password)

`/etc/mosquitto/conf.d/ocam.conf`:
```
persistence true

listener 8883
cafile   /etc/mosquitto/certs/ca.crt
certfile /etc/mosquitto/certs/server.crt
keyfile  /etc/mosquitto/certs/server.key
tls_version tlsv1.2

allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
use_username_as_clientid true

message_size_limit 32768
max_connections 200
max_queued_messages 50
max_inflight_messages 20
```

Creating the accounts:
```bash
mosquitto_passwd -c -b /etc/mosquitto/passwd cam-entree 'generated-password'   # -c: first time only
mosquitto_passwd    -b /etc/mosquitto/passwd cli-alice  'generated-password'
```

`/etc/mosquitto/acl` (one block per account; a provisioning script can generate them):
```
# administrator: monitoring and cleanup of retained states
user admin
topic readwrite ocam/#

# camera
user cam-entree
topic write ocam/dev/cam-entree/state
topic read  ocam/dev/cam-entree/in/#
topic write ocam/cli/+/in/cam-entree
topic read  ocam/config/ice

# viewer
user cli-alice
topic read  ocam/dev/+/state
topic read  ocam/cli/cli-alice/in/#
topic read  ocam/config/ice
topic write ocam/dev/+/in/cli-alice
```

Reload after a change: `kill -HUP $(pidof mosquitto)` (or `systemctl reload mosquitto`).

### Checks (to redo on every ACL change)
With the ACL active, the expected results are:
```bash
# 1. alice cannot write under bob's name: the message does not arrive (the broker ignores it without error)
mosquitto_sub -h broker -p 8883 --cafile ca.crt -u cam-entree -P ... -t 'ocam/dev/cam-entree/in/#' -v &
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/in/bob   -m x   # must NOT appear
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/in/cli-alice -m x   # must appear

# 2. a camera cannot read the others: the subscription is refused (code 128 in the SUBACK)
mosquitto_sub -h broker -p 8883 --cafile ca.crt -u cam-entree -P ... -t 'ocam/dev/+/state' -d

# 3. a viewer cannot publish a camera's state: the message is not stored
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/state -r -m '{}'
```
**Without an ACL** (test phase), all three commands succeed: that is the indicator that the ACL is not enforced.

## Appendix B — Internet exposure (checklist)

- [ ] TLS-only listener (8883), **no plaintext listener on 1883**
- [ ] `allow_anonymous false`, generated passwords of at least 20 characters, one account per device and per user
- [ ] Valid server certificate (the DNS name matches), CA pinned in the agent and in the application
- [ ] Resource limits: `message_size_limit`, `max_connections`, `max_queued_messages`, `max_inflight_messages`
- [ ] fail2ban (or equivalent) on authentication failures: Mosquitto has no native account lockout
- [ ] Logging of connections and authentication failures
- [ ] Mosquitto up to date
- [ ] Per-role ACL active and verified (appendix A)
- [ ] Revocation procedure: remove the account from `passwd` and `acl`, reload, verify the disconnection

## Appendix C — Evolution: client certificate authentication (mTLS)

Planned after the first version. It does **not** change the protocol: the client certificate's CN
replaces the username (`require_certificate true`, `use_identity_as_username true`), the ACL `user`
blocks carry the same CNs, and the topics, messages and session rules remain identical.
ECDSA P-256 keys recommended (fast generation on a low-power CPU). Details: to be written during implementation.

## Appendix D — Changes from the old protocol

| Old | New |
|---|---|
| Topics `/devices`, `/{clientID}` | `ocam/dev/{id}/state`, `ocam/dev/{id}/in/{from}`, `ocam/cli/{id}/in/{from}` |
| Shared retained message on `/devices` (a single message kept for everyone) | One retained `state` **per camera** + Last Will |
| `query` + responses from all devices | Removed: state received on subscription |
| `source` in the payload (forgeable) | Sender = last level of the topic (guaranteed by the ACL) |
| `sdp` with `data.type` offer/answer | Distinct `offer` / `answer` types |
| No session, global `hangup` | `sid`, `bye` tied to the session and the viewer |
| `error` followed by a `hangup` | `error` with a code, which terminates the session on its own |
| One `ice` message per candidate | Batched candidates, `end` |
| `streaming` boolean | `busy` + `viewer` |
| `sender` / `smartphone` type | `kind` (`relay` / `phone`), role defined by the ACL |
| `flipCamera`, `toggleCamera` | `cmd` / `res` |
| Agent id = MD5 of the RTSP URL | Id = MQTT username |
| Hard-coded Google STUN, no configuration | Optional ICE configuration (`ocam/config/ice`), default public STUN |
