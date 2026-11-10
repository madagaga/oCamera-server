# Protocole de signalisation MQTT — version 1

Ce document remplace entièrement l'ancien protocole (conservé dans `MQTT_PROTOCOL_legacy.md`, sans
version de compatibilité : l'ancien et le nouveau ne coexistent pas).

MQTT sert **uniquement à la signalisation** WebRTC (SDP, ICE), à la présence des appareils et à de
petites commandes. La vidéo et l'audio passent en pair-à-pair via WebRTC, sans transiter par le broker.

```
 Viewer (Flutter)            Broker Mosquitto              Caméra (agent Go / C, ou téléphone)
       |                           |                                |
       |-- SUBSCRIBE dev/+/state ->|<-- PUBLISH dev/{id}/state -----|  (retained + Last Will)
       |-- offer ----------------->|------------------------------->|
       |<------------------------------------------------ answer ---|
       |<========================= WebRTC P2P (vidéo/audio) ========>|
```

## 1. Hypothèses et périmètre

- **MQTT 3.1.1**, TLS, authentification **login / mot de passe** (le certificat client est une
  évolution prévue, voir annexe C).
- **Un serveur MQTT = un cercle de confiance** : tout viewer peut appeler toute caméra du serveur.
  Il n'y a pas de notion de locataire dans les topics.
- **Broker Mosquitto avec ACL par rôle** (annexe A). Les garanties d'identité et de confinement
  décrites ici **ne valent que si l'ACL est en place** (§ 9). Le protocole fonctionne sans, mais sans
  garantie de sécurité.
- **Horloge fiable (NTP)** sur tous les appareils.
- Une seule session simultanée par caméra.
- Hors périmètre : viewer web, plusieurs viewers simultanés, chiffrement applicatif des messages.
- Serveurs STUN / TURN : **optionnels**. Sans aucune configuration, les clients utilisent un STUN public
  sans identifiants (§ 5).

## 2. Identités et rôles

- L'**identifiant** d'un appareil est son **nom d'utilisateur MQTT**, et le `clientId` MQTT lui est
  égal (`use_username_as_clientid true`). Un compte par appareil, un compte par utilisateur viewer.
- Format : `[A-Za-z0-9_-]`, 3 à 32 caractères (jamais `/`, `+`, `#`). Exemples : `cam-entree`, `cli-alice`.
- Deux rôles, définis par l'ACL du broker :
  - **camera** : agent RTSP -> WebRTC, ou téléphone en mode caméra (il utilise alors un compte *caméra*,
    distinct du compte viewer de l'utilisateur) ;
  - **viewer** : application qui regarde les caméras.
- L'identifiant n'est **jamais dérivé** d'une donnée sensible (plus de MD5 de l'URL RTSP).

## 3. Topics

| Topic | Contenu | QoS | Retained | Écrit par |
|---|---|---|---|---|
| `ocam/dev/{devId}/state` | État de la caméra (§ 5) | 1 | **oui** (+ Last Will) | `devId` uniquement |
| `ocam/dev/{devId}/in/{fromId}` | Messages **vers** une caméra | 1 | non | `fromId` (un viewer) |
| `ocam/cli/{cliId}/in/{fromId}` | Messages **vers** un viewer | 1 | non | `fromId` (une caméra) |
| `ocam/config/ice` | Configuration ICE (STUN / TURN), **optionnelle** (§ 5) | 1 | **oui** | `admin` uniquement |

- **L'expéditeur est le dernier niveau du topic** (`fromId`). Il n'y a pas de champ `from` dans le
  payload : l'ACL garantit que `fromId` est le nom d'utilisateur de l'émetteur.
- Abonnements :
  - caméra : `ocam/dev/{self}/in/#` et `ocam/config/ice` (optionnel ; le téléphone caméra s'en sert pour son TURN)
  - viewer : `ocam/dev/+/state`, `ocam/cli/{self}/in/#` et `ocam/config/ice` (optionnel)
- Pas de topic de diffusion, pas de `query` : l'état retained de chaque caméra est reçu à l'abonnement.

### Paramètres de connexion

| Paramètre | Valeur |
|---|---|
| Version | MQTT 3.1.1 |
| CleanSession | `true` (agent et viewer) |
| KeepAlive | 30 s |
| Reconnexion automatique | oui, avec ré-abonnement et republication de `state` |
| TLS | oui, certificat du broker **validé** (pas d'`InsecureSkipVerify`) |
| Last Will (caméra) | topic `state`, QoS 1, retained, payload = état avec `online:false, busy:false` |
| Taille de payload max | 32 Ko ; une offre SDP fait 6 à 10 Ko, les tampons embarqués doivent faire **>= 16 Ko** |

## 4. Enveloppe des messages `in`

```json
{ "v": 1, "ts": 1760000000, "sid": "k3f9x2m1q8", "type": "offer", "data": { } }
```

| Champ | Type | Description |
|---|---|---|
| `v` | entier | Version du protocole (`1`). Un message avec un `v` supérieur est ignoré. |
| `ts` | entier | Secondes Unix UTC à l'émission. Le récepteur **ignore** les messages dont `|maintenant - ts| > 30 s`. |
| `sid` | chaîne | Identifiant de session (8 à 32 caractères, aléatoire), **choisi par le viewer** à l'offre. Absent pour `cmd` / `res`. |
| `type` | chaîne | `offer`, `answer`, `ice`, `bye`, `error`, `cmd`, `res` |
| `data` | objet | Contenu spécifique au type |

Règles générales :
- Les champs inconnus et les types inconnus sont **ignorés** (journalisés), jamais source d'erreur.
- JSON valide uniquement ; toute valeur textuelle doit être **échappée** par un vrai sérialiseur
  (jamais de construction par concaténation).
- Une caméra dont l'horloge n'est pas encore synchronisée (année < 2024) saute le contrôle de `ts`
  jusqu'à la première synchronisation.
- Un message ignoré pour cause de `ts` hors tolérance est signalé dans les journaux. Seule une
  `offer` reçoit en retour une `error` (`stale`).

## 5. État d'une caméra (`state`)

Publié à la connexion, à chaque changement, et envoyé automatiquement par le broker (Last Will)
à la déconnexion. **Retained**.

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

| Champ | Type | Description |
|---|---|---|
| `name` | chaîne (<= 64) | Nom affiché |
| `online` | booléen | `false` dans le Last Will |
| `busy` | booléen | Une session est active (remplace l'ancien `streaming`) |
| `viewer` | chaîne ou `null` | Identifiant du viewer de la session en cours |
| `kind` | chaîne | `relay` (agent RTSP) ou `phone` (téléphone caméra), indicatif |
| `caps` | objet (optionnel) | Capacités : `video`, `audio` (codecs en minuscules), `streams`, `cmds`. Si absent, le viewer conserve les dernières capacités connues. |
| `agent` | objet (optionnel) | Implémentation et version, indicatif |
| `facing` | chaîne (optionnel) | Caméra utilisée par un téléphone pendant une session : `back` (arrière) ou `front` (avant). Absent hors session ou si la caméra ne le sait pas ; le viewer n'affiche rien dans ce cas. Republié après chaque `flip` réussi. |
| `battery` | objet (optionnel) | Batterie d'un appareil qui en a une (téléphone caméra) : `level` (entier 0 à 100) et `charging` (booléen, `true` si une alimentation externe est branchée, même batterie pleine). Absent pour une caméra sur secteur ; le viewer n'affiche rien dans ce cas. Republié quand l'état de charge change, quand le niveau varie d'au moins 5 points, ou à chaque variation sous 20 %, au plus toutes les 5 minutes. |

- Le **Last Will** contient l'état complet avec `online:false` et `busy:false` (le nom est connu à la connexion).
- **Retrait d'un appareil** : l'administrateur publie un message retained **vide** sur son `state`
  (`mosquitto_pub -r -n`). Un viewer qui reçoit un payload vide sur un `state` retire l'appareil de sa liste.
- Les viewers **n'annoncent pas** leur présence.

### Configuration ICE (optionnelle)

Un message **retained** que l'administrateur publie sur `ocam/config/ice` pour que les viewers
n'aient pas à saisir de serveurs STUN / TURN. Il est lisible par les **viewers** et par les **caméras** qui en ont
besoin (le téléphone en mode caméra, qui est un pair WebRTC complet ; un agent comme l'agent Go n'a besoin que d'un STUN,
configuré localement).

```json
{
  "v": 1,
  "ts": 1760000000,
  "stun": ["stun:turn.exemple.fr:3478"],
  "turn": {
    "urls": ["turn:turn.exemple.fr:3478?transport=udp", "turns:turn.exemple.fr:5349?transport=tcp"],
    "username": "1762592000:ocam",
    "credential": "base64...",
    "expires": 1762592000
  }
}
```

| Champ | Description |
|---|---|
| `stun` | (optionnel) Liste d'URL STUN. Un STUN n'a pas d'identifiants. |
| `turn` | (optionnel) Un serveur TURN. |
| `turn.username`, `turn.credential` | (**optionnels**) À omettre pour un serveur sans authentification. |
| `turn.expires` | (optionnel) Expiration des identifiants, secondes Unix ; informatif. |

Ordre de priorité côté viewer pour construire ses `iceServers` :
1. réglages saisis manuellement dans l'application (s'ils existent) ;
2. sinon le message `ocam/config/ice` (s'il existe et est valide) ;
3. sinon **STUN public par défaut**, sans identifiants (`stun:stun.l.google.com:19302`,
   `stun1.l.google.com:19302`).

Le message est entièrement facultatif : un broker sans ce topic fonctionne normalement. Un message
absent, vide ou invalide est ignoré. Le viewer relit la valeur retained à chaque connexion MQTT.

## 6. Messages

Tous sont publiés sur `ocam/dev/{devId}/in/{fromId}` (vers une caméra) ou
`ocam/cli/{cliId}/in/{fromId}` (vers un viewer), avec l'enveloppe du § 4.

### `offer` — viewer -> caméra
```json
{ "v":1, "ts":1760000000, "sid":"k3f9x2m1q8", "type":"offer",
  "data": { "sdp": "v=0\r\no=- ...", "want": { "stream": "sub", "audio": true } } }
```
| `data` | Description |
|---|---|
| `sdp` | Offre SDP (le viewer reçoit : `recvonly` vidéo et audio) |
| `want.stream` | (optionnel) Flux demandé parmi `caps.streams` ; défaut : le premier |
| `want.audio` | (optionnel) `false` pour ne pas recevoir l'audio |

### `answer` — caméra -> viewer
```json
{ "v":1, "ts":1760000001, "sid":"k3f9x2m1q8", "type":"answer", "data": { "sdp": "v=0\r\n..." } }
```

### `ice` — dans les deux sens
```json
{ "v":1, "ts":1760000002, "sid":"k3f9x2m1q8", "type":"ice",
  "data": { "candidates": [ { "candidate":"candidate:1 1 UDP 2113937151 192.168.1.10 54321 typ host",
                              "sdpMid":"0", "sdpMLineIndex":0 } ], "end": false } }
```
| `data` | Description |
|---|---|
| `candidates` | Un ou plusieurs candidats. `sdpMid` et `sdpMLineIndex` peuvent être `null` (pas d'exception à la lecture). |
| `end` | `true` après le dernier candidat (liste éventuellement vide) |

- Les émetteurs **regroupent** les candidats (fenêtre d'environ 100 ms) plutôt qu'un message par candidat.
- Les récepteurs acceptent le **trickle** (candidats après l'`offer` / `answer`) comme le **non-trickle**
  (candidats déjà dans le SDP, aucun `ice` envoyé).

### `bye` — fin de session, dans les deux sens
```json
{ "v":1, "ts":1760000300, "sid":"k3f9x2m1q8", "type":"bye", "data": { "reason": "user" } }
```
`reason` (optionnel) : `user`, `timeout`, `ice_failed`, `source_lost`, `shutdown`.

### `error` — caméra -> viewer
```json
{ "v":1, "ts":1760000001, "sid":"k3f9x2m1q8", "type":"error",
  "data": { "code": "busy", "message": "session déjà active", "retryable": true } }
```
| `code` | Signification |
|---|---|
| `busy` | Une session est déjà active |
| `bad_request` | Message ou SDP invalide, flux demandé inexistant |
| `unsupported_codec` | Aucun codec commun |
| `source_unavailable` | Flux source (RTSP) injoignable |
| `stale` | `ts` hors tolérance (probable problème d'horloge) |
| `internal` | Autre erreur côté caméra |

Une `error` **termine** la session : elle n'est jamais suivie d'un `bye`.

### `cmd` / `res` — commandes (hors session)
```json
{ "v":1, "ts":1760000400, "type":"cmd", "data": { "id":"c-17", "name":"torch", "args": { "on": true } } }
{ "v":1, "ts":1760000401, "type":"res", "data": { "id":"c-17", "ok": true } }
{ "v":1, "ts":1760000401, "type":"res", "data": { "id":"c-18", "ok": false,
                                                 "error": { "code":"unsupported", "message":"..." } } }
```
- Pas de `sid`. La commande est identifiée par `data.id` ; le `res` est publié sur la boîte du viewer.
- Les commandes disponibles sont listées dans `caps.cmds`. Noms standard : `flip` (changer de caméra
  d'un téléphone), `torch` (`args.on`), `video` et `audio` (`args.on` booléen : coupe ou rétablit
  l'envoi de la vidéo ou du son de la session en cours ; réservées au viewer de cette session, sinon
  `ok:false` / `unavailable` ; sans piste correspondante, couper répond `ok:true` et rétablir
  `unavailable`). La piste est seulement désactivée (`enabled=false`) : la session et la capture
  restent ouvertes, l'image devient noire et le débit tombe, la reprise est immédiate. Noms propres à une implémentation : préfixe `x-`.
- Une commande inconnue reçoit un `res` avec `ok:false` et le code `unsupported`.
- Délai de réponse attendu : 10 s.
- L'ancien `flipCamera` / `toggleCamera` disparaît, remplacé par `cmd` `flip`.

## 7. Règles de session (côté caméra)

La caméra est dans l'un des deux états `idle` ou `busy(sid, viewer)`.

| Événement | En `idle` | En `busy` |
|---|---|---|
| `offer` valide | crée la session, répond `answer`, passe en `busy`, republie `state` (`busy:true`, `viewer`) | même `sid` **et** même viewer : **doublon**, renvoie la même `answer` (ou ignore) ; sinon `error busy` au viewer émetteur, **session active inchangée** |
| `offer` invalide | `error` (`bad_request`, `unsupported_codec`, `source_unavailable`, `stale`), reste `idle` | `error busy` |
| `ice` | ignoré | accepté **seulement** si `sid` et viewer correspondent à la session |
| `bye` | ignoré | accepté **seulement** si `sid` et viewer correspondent ; ferme la session |
| `cmd` | traité | traité |

Fin de session :
- `bye` du viewer ;
- échec ou perte de la connexion WebRTC (état `failed`, ou `disconnected` > 10 s) : la caméra envoie
  `bye` (`reason: ice_failed`) ;
- aucune connexion établie dans les **30 s** après l'`answer` : `bye` (`reason: timeout`) ;
- source RTSP perdue après les tentatives de reconnexion : `bye` (`reason: source_lost`).

Après la fin : fermeture de la PeerConnection et du flux RTSP, republication de `state`
(`busy:false`, `viewer:null`).

Autres règles :
- **La perte de la connexion MQTT ne coupe pas** une session WebRTC déjà établie (la signalisation
  n'est plus nécessaire). À la reconnexion, la caméra republie son `state` exact.
- Le **viewer** ignore tout message dont le `sid` n'est pas celui de son appel en cours.
- Le **viewer** envoie `bye` à la fin d'un appel ; s'il disparaît sans le faire, la caméra le détecte
  par l'expiration de la connexion WebRTC.
- L'ouverture du flux RTSP se fait **après** l'établissement de la connexion WebRTC (inchangé).
- **Journal de session** (obligatoire côté caméra) : début (`sid`, viewer), fin (raison, durée).

## 8. Flux

### Appel nominal
```
Viewer                       Broker                       Caméra
  |-- offer (sid=S) ---------->|-- ocam/dev/cam/in/cli --->|
  |                            |                           | crée la PeerConnection
  |<-- answer (sid=S) ---------|<-- ocam/cli/cli/in/cam ---|  state: busy=true, viewer=cli
  |<-- ice (sid=S) ------------|<--------------------------|  (candidats par lots)
  |-- ice (sid=S) ------------>|-------------------------->|
  |========= connexion WebRTC établie : la caméra ouvre le RTSP =========|
  |-- bye (sid=S) ------------>|-------------------------->|  state: busy=false
```

### Caméra occupée (second viewer)
```
Viewer B                                                   Caméra (busy avec A)
  |-- offer (sid=T) ------------------------------------------>|
  |<-- error (sid=T, code=busy) --------------------------------|   la session de A est inchangée
```

### Coupure d'alimentation de la caméra
```
Caméra ---X (plus de keepalive)
Broker : publie le Last Will  ->  state { online:false, busy:false }   (retained)
Viewers : affichent la caméra hors ligne
```

## 9. Sécurité

- **Authentification** : login / mot de passe MQTT, TLS obligatoire avec **certificat du broker validé**.
- **Autorisation** : ACL Mosquitto **par rôle** (annexe A). Elle garantit que :
  - un client n'écrit dans une boîte que sous son propre nom (`fromId` fiable) ;
  - un client ne lit que sa propre boîte ;
  - une caméra n'écrit que son propre `state`, ne lit pas les autres caméras et n'appelle personne ;
  - un viewer ne publie jamais d'état de caméra.
- **Ce que l'ACL ne couvre pas** : un compte *viewer* volé donne accès à toutes les caméras du serveur
  jusqu'à sa révocation (modèle « un serveur = un cercle de confiance »). Parades : un compte par
  viewer (révocable), mots de passe longs générés, journal de session, détection par éjection
  (deux connexions avec le même compte -> la première est éjectée).
- **Auto-test de l'ACL** (agent caméra, recommandé) : au démarrage, l'agent tente de s'abonner à
  `ocam/dev/+/state` (interdit à une caméra). Si le broker **accepte** l'abonnement, l'agent journalise
  un avertissement visible (« broker permissif : l'ACL n'est pas appliquée ») et démarre quand même.
- Les mots de passe ne figurent **jamais** dans les journaux.
- Le broker est la racine de confiance : l'empreinte DTLS du SDP transite par lui.

## Annexe A — Configuration Mosquitto (login / mot de passe)

`/etc/mosquitto/conf.d/ocam.conf` :
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

Création des comptes :
```bash
mosquitto_passwd -c -b /etc/mosquitto/passwd cam-entree 'mot-de-passe-genere'   # -c : première fois seulement
mosquitto_passwd    -b /etc/mosquitto/passwd cli-alice  'mot-de-passe-genere'
```

`/etc/mosquitto/acl` (un bloc par compte ; un script de provisionnement pourra les générer) :
```
# administrateur : supervision et nettoyage des états retained
user admin
topic readwrite ocam/#

# caméra
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

Rechargement après modification : `kill -HUP $(pidof mosquitto)` (ou `systemctl reload mosquitto`).

### Vérifications (à refaire à chaque changement d'ACL)
Avec l'ACL active, les résultats attendus sont :
```bash
# 1. alice ne peut pas écrire sous le nom de bob : le message n'arrive pas (le broker l'ignore sans erreur)
mosquitto_sub -h broker -p 8883 --cafile ca.crt -u cam-entree -P ... -t 'ocam/dev/cam-entree/in/#' -v &
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/in/bob   -m x   # NE doit PAS apparaître
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/in/cli-alice -m x   # doit apparaître

# 2. une caméra ne peut pas lire les autres : l'abonnement est refusé (code 128 dans le SUBACK)
mosquitto_sub -h broker -p 8883 --cafile ca.crt -u cam-entree -P ... -t 'ocam/dev/+/state' -d

# 3. un viewer ne peut pas publier l'état d'une caméra : le message n'est pas stocké
mosquitto_pub -h broker -p 8883 --cafile ca.crt -u cli-alice -P ... -t ocam/dev/cam-entree/state -r -m '{}'
```
**Sans ACL** (phase de test), les trois commandes réussissent : c'est l'indicateur que l'ACL n'est pas appliquée.

## Annexe B — Exposition sur Internet (checklist)

- [ ] Listener TLS seul (8883), **pas de listener 1883** en clair
- [ ] `allow_anonymous false`, mots de passe générés d'au moins 20 caractères, un compte par appareil et par utilisateur
- [ ] Certificat serveur valide (le nom DNS correspond), CA épinglé dans l'agent et dans l'application
- [ ] Limites de ressources : `message_size_limit`, `max_connections`, `max_queued_messages`, `max_inflight_messages`
- [ ] fail2ban (ou équivalent) sur les échecs d'authentification : Mosquitto n'a pas de verrouillage de compte natif
- [ ] Journalisation des connexions et des échecs d'authentification
- [ ] Mosquitto à jour
- [ ] ACL par rôle active et vérifiée (annexe A)
- [ ] Procédure de révocation : retirer le compte de `passwd` et de `acl`, recharger, vérifier la déconnexion

## Annexe C — Évolution : authentification par certificat client (mTLS)

Prévue après la première version. Elle ne change **pas** le protocole : le CN du certificat client
remplace le nom d'utilisateur (`require_certificate true`, `use_identity_as_username true`), les blocs
`user` de l'ACL portent les mêmes CN, et les topics, messages et règles de session restent identiques.
Clés ECDSA P-256 recommandées (génération rapide sur CPU faible). Détails : à écrire lors de la mise en œuvre.

## Annexe D — Changements par rapport à l'ancien protocole

| Ancien | Nouveau |
|---|---|
| Topics `/devices`, `/{clientID}` | `ocam/dev/{id}/state`, `ocam/dev/{id}/in/{from}`, `ocam/cli/{id}/in/{from}` |
| Retained partagé sur `/devices` (un seul message conservé pour tous) | Un `state` retained **par caméra** + Last Will |
| `query` + réponses de tous les devices | Supprimé : état reçu à l'abonnement |
| `source` dans le payload (falsifiable) | Expéditeur = dernier niveau du topic (garanti par l'ACL) |
| `sdp` avec `data.type` offer/answer | Types distincts `offer` / `answer` |
| Pas de session, `hangup` global | `sid`, `bye` rattaché à la session et au viewer |
| `error` suivi d'un `hangup` | `error` avec code, qui termine la session seul |
| Un message `ice` par candidat | Candidats regroupés, `end` |
| `streaming` booléen | `busy` + `viewer` |
| Type `sender` / `smartphone` | `kind` (`relay` / `phone`), rôle défini par l'ACL |
| `flipCamera`, `toggleCamera` | `cmd` / `res` |
| Id de l'agent = MD5 de l'URL RTSP | Id = nom d'utilisateur MQTT |
| STUN Google codé en dur, aucune configuration | Configuration ICE optionnelle (`ocam/config/ice`), STUN public par défaut |
