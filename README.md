# Serveur oCamera : Mosquitto + STUN / TURN (Docker)

Un `docker compose` qui monte tout ce dont les caméras et les viewers ont besoin côté serveur :

| Service | Rôle | Ports |
|---|---|---|
| `mosquitto` | Signalisation MQTT 3.1.1 en TLS, login / mot de passe, ACL par rôle ([MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md), annexe A) | 8883/tcp |
| `coturn` | STUN + TURN (identifiants temporaires), voir [STUN_TURN.md](../STUN_TURN.md) | 3478 udp+tcp, 5349 tcp (TLS), 49152-49252 udp |
| `ice-publisher` | Publie chaque jour les identifiants TURN sur `ocam/config/ice` (retained). Viewers **et caméras** la lisent | — |

Cible : un serveur **Linux** avec une IP publique. `coturn` utilise le réseau de l'hôte (`network_mode: host`) : il
ne fonctionne donc pas sous Docker Desktop (Windows / macOS), seulement pour les tests de syntaxe.

## Prérequis

- Docker et Docker Compose v2.
- Deux noms DNS pointant sur le serveur (ils peuvent être identiques) : `MQTT_HOST` et `TURN_HOST`.
- Un certificat TLS valide pour ces noms (Let's Encrypt par exemple), copié dans `./certs/` :
  - `certs/fullchain.pem`
  - `certs/privkey.pem`
- Pare-feu ouvert : 8883/tcp, 3478/udp+tcp, 5349/tcp, 49152-49252/udp.

## Démarrage

```bash
cp .env.example .env          # puis éditer : noms DNS, IP publique, secrets
openssl rand -hex 32          # à coller dans TURN_SECRET

./scripts/init.sh             # crée le compte admin et l'ACL
docker compose up -d --build
docker compose logs -f
```

Les scripts sont en bash (`bash scripts/init.sh` si le bit exécutable manque).

### Droits sur les certificats

Mosquitto (uid 1883) et coturn lisent les fichiers de `./certs`. Avec Let's Encrypt, un *deploy hook* de certbot
qui copie les fichiers puis les rend lisibles suffit, par exemple :

```bash
cp /etc/letsencrypt/live/$DOMAINE/{fullchain,privkey}.pem ./certs/
chmod 644 ./certs/fullchain.pem
chmod 640 ./certs/privkey.pem && chown root:1883 ./certs/privkey.pem
docker compose restart mosquitto coturn   # après chaque renouvellement
```

Si coturn ne peut pas lire la clé (utilisateur différent), il désactive le TLS : vérifier dans ses logs.

## Comptes MQTT

```bash
./scripts/user.sh add cam-entree camera   # agent Go / C ou téléphone caméra seul
./scripts/user.sh add alice viewer        # viewer seul
./scripts/user.sh add tel-jardin phone    # l'app Flutter : caméra + viewer avec le même compte
./scripts/user.sh remove alice
```

Le script écrit le mot de passe (haché) et le bloc d'ACL du compte, puis recharge Mosquitto. Chaque bloc donne aussi
la **lecture de `ocam/config/ice`** : une caméra en a besoin pour recevoir le TURN (le [protocole](../MQTT_PROTOCOL.md)
la réservait aux viewers, mais le téléphone caméra la lit maintenant).

Un rechargement ne déconnecte pas un client déjà connecté : après un `remove`, redémarrer Mosquitto
(`docker compose restart mosquitto`) pour couper la session en cours.

## Vérifications

```bash
# ICE publié ? (doit renvoyer le JSON avec stun / turn)
docker compose exec mosquitto mosquitto_sub -h localhost -p 8883 \
  --cafile /mosquitto/certs/fullchain.pem -u admin -P "$MQTT_ADMIN_PASSWORD" -t ocam/config/ice -C 1
```

Les contrôles d'ACL de l'annexe A du protocole (alice qui écrit sous un autre nom, une caméra qui lit les autres, etc.)
restent à refaire après chaque changement.

- STUN : `turnutils_stunclient $TURN_HOST` renvoie l'adresse publique de l'appelant.
- TURN : dans l'app, le badge de la vue live affiche `Relayed` quand le relais est utilisé. Logs de l'app :
  `[MQTT] : ICE config 2 server entries` côté viewer **et** caméra.
- Test à faire depuis un viewer en 4G/5G, avec et sans TURN.

## Certificat auto-signé (réseau local, tests)

Placer `fullchain.pem`, `privkey.pem` et la CA (`ca.crt`) dans `./certs`, puis mettre `MQTT_CAFILE=/certs/ca.crt`
dans `.env` pour le publisher. Les apps valident le certificat : il faut installer la CA sur les téléphones.

## Notes

- `--denied-peer-ip` : coturn refuse de relayer vers les réseaux privés. Si le serveur est sur **le même réseau
  local** que les caméras, adapter ces lignes dans `docker-compose.yml`.
- Si le serveur est derrière un NAT, mettre `IP_PUBLIQUE/IP_PRIVEE` dans `EXTERNAL_IP` et rediriger les ports ci-dessus.
- Les identifiants TURN durent 30 jours et sont republiés chaque jour : rien à renouveler à la main.
- `mosquitto/config/` (mots de passe, ACL), `certs/` et `.env` ne sont jamais versionnés (`.gitignore`).
