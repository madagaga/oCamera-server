# STUN / TURN — déploiement avec coturn (optionnel)

**Tout est optionnel.** Sans rien installer ni configurer, les clients utilisent le STUN public de Google :
c'est un STUN **sans mot de passe** (Google ne propose pas de TURN public). Cela suffit tant que les
connexions directes réussissent.

coturn fait **STUN et TURN** : un seul service si vous décidez d'héberger les vôtres.

## Trois niveaux

| Niveau | Ce qu'on installe | Identifiants | Quand |
|---|---|---|---|
| **0 — par défaut** | Rien | Aucun | Début ; les viewers en 4G/5G réussissent |
| **1 — STUN à soi** | coturn (STUN seul, sans compte) | Aucun | Ne plus dépendre de Google |
| **2 — STUN + TURN** | coturn avec relais | **Identifiants temporaires, publiés par MQTT** (voir ci-dessous) | Un viewer mobile échoue en connexion directe (NAT symétrique / CGNAT) |

Le message MQTT `ocam/config/ice` (`MQTT_PROTOCOL.md`, § 5) est **facultatif** et `username` /
`credential` y sont facultatifs : un STUN seul, ou un serveur sans authentification, se décrit sans eux.

## Qui a besoin de quoi

| Composant | STUN | TURN |
|---|---|---|
| Agent caméra (Go / C) | oui, URL **configurable** (`ice.stun`, défaut Google) | **non** (l'agent envoie vers l'adresse de relais du viewer comme vers n'importe quel candidat) |
| Viewer Flutter | oui | oui, si configuré |

Côté viewer, la priorité est : réglages saisis à la main > message `ocam/config/ice` > STUN Google par défaut.

## Niveau 1 — STUN seul (sans compte)

Le STUN de coturn est ouvert (il ne relaie rien). Un fichier de configuration minimal :

```
listening-port=3478
external-ip=IP_PUBLIQUE
fingerprint
no-tcp-relay        # pas de TURN : aucune ressource de relais
```
Pare-feu : UDP 3478 (et TCP 3478). Aucun identifiant à créer.

## Niveau 2 — STUN + TURN avec identifiants temporaires

Pas de liste de comptes dans coturn : un **secret partagé** sert à calculer des identifiants à durée
limitée. Il n'y a donc **rien à dupliquer avec Mosquitto** : retirer un utilisateur ne touche que
Mosquitto.

`/etc/turnserver.conf` :
```
listening-port=3478
tls-listening-port=5349
external-ip=IP_PUBLIQUE            # ou IP_PUBLIQUE/IP_PRIVEE si le serveur est derrière un NAT
realm=turn.exemple.fr
fingerprint

use-auth-secret
static-auth-secret=SECRET_LONG_GENERE

min-port=49152
max-port=49252

cert=/etc/coturn/certs/fullchain.pem
pkey=/etc/coturn/certs/privkey.pem

user-quota=4
total-quota=50
no-multicast-peers
no-cli

# ne pas relayer vers les réseaux privés (protège le réseau du serveur)
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
```
- `denied-peer-ip` : si coturn est sur **le même réseau local** que les caméras, ajuster ou retirer ces lignes.
- La combinaison `use-auth-secret` / `static-auth-secret` est à valider sur votre version de coturn
  avec `turnutils_uclient` (voir « Vérification »).

### Publication des identifiants par MQTT

Un script exécuté **une fois par jour** (cron) sur le serveur calcule les identifiants (valables
30 jours) et les publie en retained : il en reste donc toujours au moins 29 jours, et une fuite expire seule.

`/usr/local/bin/ocam-publish-ice` :
```bash
#!/bin/sh
# Variables : SECRET = static-auth-secret de coturn ; mot de passe admin dans un fichier chmod 600
SECRET='SECRET_LONG_GENERE'
HOST='turn.exemple.fr'
BROKER='mqtt.exemple.fr'
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

Pour un **STUN seul** (niveau 1), le même script publie sans le bloc `turn` (ou on publie le JSON à la main une fois).

## Pare-feu à ouvrir

| Port | Protocole | Usage | Niveau |
|---|---|---|---|
| 3478 | UDP et TCP | STUN / TURN | 1 et 2 |
| 5349 | TCP (et UDP) | TURN sur TLS (traverse les réseaux restrictifs) | 2 |
| 49152-49252 | UDP | Relais média | 2 |

## Configuration des clients

**Agent** (un seul paramètre, optionnel) :
```yaml
ice:
  stun: "stun:turn.exemple.fr:3478"   # défaut si absent : STUN public Google
```

**Viewer** : rien à saisir si `ocam/config/ice` est publié. Sinon, STUN Google par défaut ; les URLs et
identifiants éventuels se saisissent dans les réglages avancés de l'application (priorité sur le reste).

## Vérification
- STUN : `turnutils_stunclient turn.exemple.fr` doit renvoyer l'adresse publique de la machine appelante.
- TURN : générer un couple temporaire avec le script ci-dessus puis
  `turnutils_uclient -u "<username>" -w "<credential>" turn.exemple.fr` doit réussir une allocation.
- Lecture de la config : `mosquitto_sub -t ocam/config/ice -C 1 ...` doit renvoyer le message retained.
- En usage réel : l'écran de diagnostic `getStats()` du viewer doit montrer le type de candidat
  sélectionné. `relay` = le TURN est utilisé ; `srflx` ou `host` = connexion directe.
- Test à faire depuis un viewer en 4G/5G, avec plusieurs opérateurs si possible, **avec** et **sans** TURN.
