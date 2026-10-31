# the-evil-cloud-03 — 5 nœud(s), 1 protocole(s)

Un seul conteneur : **nginx** répartit les chemins, **Xray** sert un inbound par nœud.
Région : `europe-west1` · Port exposé : 8080 · Service : `the-evil-cloud-03`

## Pourquoi un répartiteur

Cloud Run n'ouvre **qu'un seul port** (8080) et termine le TLS lui-même.
Xray ne peut donc pas écouter VLESS, VMess et Trojan sur la même porte.
nginx lit le chemin de la requête et envoie chacun vers son Xray local :
tout le monde passe par la porte 8080, chacun repart dans son couloir.

## Les nœuds de ce service

| Nœud | Protocole | Chemin | Identité | Expire |
|---|---|---|---|---|
| vmess-03-1 | VMess | `/🦋🐉` | `🎭🧊☠` | jamais |
| vmess-03-2 | VMess | `/🐺🦋🐉` | `🐉🧿🌵` | jamais |
| vmess-03-3 | VMess | `/🦂🐺🦋🐉` | `🧿🌵🐢` | jamais |
| vmess-03-4 | VMess | `/⚡🦂` | `🙃😘⚡` | jamais |
| vmess-03-5 | VMess | `/🐙⚡🦂` | `🙁🐉🧿` | jamais |

Chaque nœud a **sa propre identité** et **son propre chemin** : dans le client,
ce sont des serveurs distincts. Le protocole, l'identité et le chemin doivent
être strictement identiques entre ce dépôt et le lien collé dans le client.

## L'expiration, et ce qu'elle coupe vraiment

Xray **ne sait pas** expirer un utilisateur tout seul : les champs `expiryTime`
des tutos viennent des panneaux (3x-ui, Marzban), pas du binaire. Le champ est
donc ignoré si tu l'écris dans `config.json`.

Ici, l'expiration est tenue par `watchdog.sh` : une boucle dans le conteneur qui
relit `expiry.txt` toutes les 20 secondes et **éjecte** du serveur les clients
dont l'échéance est passée, via l'API locale de Xray.

- Délai réel : **20 secondes maximum** après l'échéance.
- Aucun redéploiement, aucune action de ta part.
- Les connexions déjà ouvertes tiennent jusqu'à leur prochaine poignée de main ;
  Cloud Run coupe de toute façon à 60 minutes.

## La aussi, `expiry.txt` a une ligne par client expirable : `<epoch>|<tag>|<email>`.
Un nœud « sans expiration » n'y figure simplement pas.

## Le quota, les appareils, et les compteurs réels

`limits.txt` porte une ligne par client : `<tag>|<email>|<appareils max>|<gigas max>`.
Le gardien relit ce fichier toutes les 20 s : au-delà de la limite, il retire
le client du serveur (`rmu`). `0` veut dire « aucune limite » — et c'est le
défaut, parce que tous les utilisateurs partagent la même identité : une
limite trop basse éjecterait tout le monde d'un coup.

En parallèle, le gardien écrit `/tmp/stats.json`, servi par nginx sur
`/stats.json` : volumes montants/descendants par client et adresses IP vues.
C'est ce fichier que le panneau lit pour afficher le trafic réel du serveur.
Aucune identité n'y figure.

```
curl -s https://the-evil-cloud-03-xxxxx.europe-west1.run.app/stats.json
```

Un `404` sur `/stats.json` veut dire que la révision déployée est antérieure à
cette version : le panneau affichera alors « non mesuré », jamais un faux zéro.
Si l'API de Xray ne répond pas aux commandes de comptage, la liste `online`
reste vide : le nombre d'appareils n'est simplement pas mesuré, et aucune
limite d'appareils ne s'applique. Le quota de gigas, lui, continue de marcher.

## Mise en route — le dépôt GitHub, puis Cloud Run

1. Dans le panneau : **Télécharger le .zip**, puis **décompresse-le**.
2. Crée un dépôt **privé** (le `config.json` contient toutes les identités),
   de préférence nommé comme le service : `the-evil-cloud-03`.
3. Sur la page du dépôt vide : **Add file → Upload files**, glisse le *contenu*
   du dossier décompressé (pas le dossier lui-même), puis **Commit changes**.
4. Recrée `.github/workflows/deploy.yml` **à la main** : l'étape que tout le
   monde rate, détaillée juste en dessous.
5. Branche le dépôt sur Cloud Run : **console → Créer un service → Déployer en
   continu à partir d'un dépôt → GitHub → ce dépôt**, branche `main`, Dockerfile.
   Nom : `the-evil-cloud-03` · région `europe-west1` · port 8080.
   Google se connecte au dépôt et rebuild à chaque push : aucune clé à fabriquer.

### ⚠️ Le glisser-déposer jette `.github` sans rien dire

GitHub ignore **silencieusement** tout dossier qui commence par un point. Le
`deploy.yml` n'arrive donc jamais dans le dépôt, et un `git push` ne redéploie
rien : on croit le workflow cassé alors que le fichier n'existe pas.

La parade, en 20 secondes :

1. Dans le dépôt : **Add file → Create new file**.
2. Dans le champ du nom, tape le chemin complet
   `.github/workflows/deploy.yml` : les slashs créent les dossiers tout seuls.
3. Colle le contenu du fichier (bouton **Copier** dans le panneau), puis Commit.

Le workflow a besoin d'une clé de compte de service : **Settings → Secrets and
variables → Actions → New repository secret**, nom `GCP_SA_KEY`. Sans clé,
utilise simplement la connexion directe du point 5.

### Le dépôt doit contenir exactement

```
Dockerfile
config.json
nginx.conf
entrypoint.sh
watchdog.sh
expiry.txt
limits.txt
control.env
.github/workflows/deploy.yml
README.md
```

`Dockerfile` doit être à la **racine** et s'écrire exactement comme ça, sans
extension : sinon Cloud Build répond `no buildable source found`.

## Déployer sans passer par la console

Depuis un clone du dépôt, ou dans **Cloud Shell** (bouton `>_` en haut à droite
de la console Google Cloud, déjà connecté au bon projet) :

```
gcloud run deploy the-evil-cloud-03 --source . --region europe-west1 --allow-unauthenticated --port 8080 --memory 512Mi --cpu 1 --timeout 3600
```

Ce nom — `the-evil-cloud-03` — est le seul qui compte. S'il diffère ne serait-ce
que d'un caractère, gcloud **crée un autre service** au lieu de mettre à jour
celui dont tu ouvres l'URL, et ce dernier garde son ancien contenu pour toujours.

À la fin, gcloud affiche `Service URL: https://….run.app`.

Si l'upload GitHub coince, le panneau propose une voie de secours sans dépôt :
le même zip part directement dans Cloud Shell (`unzip *.zip -d depot`, puis la
commande ci-dessus). On perd le redéploiement automatique, mais ça dépanne.

## Vérifier en 10 secondes que c'est bien CE conteneur

```
curl -s https://the-evil-cloud-03-xxxxx.europe-west1.run.app/
```

Réponse attendue :

```
dgm-cloud-run-stack | service=the-evil-cloud-03 | nodes=5 | protocols=…
```

Si tu lis `Welcome to nginx!`, ce n'est pas ce dépôt : c'est l'échantillon créé
par la console. Ton déploiement a visé un autre nom de service, ou la nouvelle
révision n'a pas pris le trafic.

```
curl -s https://the-evil-cloud-03-xxxxx.europe-west1.run.app/healthz
```

`ok` → les deux processus tournent. `502` / `503` → les logs de la révision
donnent la ligne exacte (`nginx: [emerg]`, ou `Xray n a pas demarre`).

## La sonde : ce que le conteneur sert vraiment

```
curl -s https://the-evil-cloud-03-xxxxx.europe-west1.run.app/stack.json
```

Réponse (aucune identité dedans, seulement les chemins) :

```json
{ "stack": "dgm-cloud-run-stack", "service": "…", "count": 30,
  "protocols": ["VLESS", "VMess", "Trojan"],
  "nodes": [{ "name": "vless-01", "protocol": "VLESS", "path": "/v01…", "port": 10001 }] }
```

C'est le seul moyen de trancher le cas le plus fréquent : **« VMess et
Trojan refusent mais VLESS passe »**. Deux causes opposées, même symptôme :

- la liste ne contient que `VLESS` → la révision qui répond est plus
  ancienne que ce dépôt. Recopie tout le .zip, commit, puis redéploie.
- la liste contient les trois protocoles **et** le chemin du nœud qui
  refuse → le serveur est bon, le problème est dans le lien ou dans le
  client (profil recréé à la main, `host=` manquant, TLS du client).

Le panneau fait cette comparaison pour toi : bouton **Sonder le conteneur**,
juste au-dessus de ces fichiers. Un `404` sur `/stack.json` veut dire que
la révision déployée ne contient même pas cette sonde — donc elle est
antérieure à ce dépôt, et c'est là qu'il faut commencer.

## Redéployer après un changement

Si le dépôt est branché sur Cloud Run (déploiement continu), un simple commit
sur `main` suffit : la révision se reconstruit, l'URL ne bouge pas.

- Modifier `expiry.txt` puis redéployer = le gardien applique les nouvelles
  échéances au démarrage suivant.
- Modifier `config.json` ou `nginx.conf` = **redéploiement obligatoire** : ces
  fichiers sont lus une seule fois, au démarrage du conteneur.

En local, si tu préfères la ligne de commande :

```
git init
git remote add origin https://github.com/TON_COMPTE/the-evil-cloud-03.git
git add .
git commit -m "stack cloud run"
git push -u origin main
```

`git add .` embarque bien `.github/` : le piège ne concerne que le glisser-déposer
du navigateur.

## ⚠️ Le nom du service decide de tout

`gcloud run deploy` ne « met pas a jour un service » : il cree ou met a jour
**le service dont tu lui donnes le nom**. Deux noms differents = deux services
distincts, deux URL distinctes, et deux conteneurs qui n'ont rien a voir.

Une URL Cloud Run se lit comme ca :

```
https://[etiquette---]NOM_DU_SERVICE-NUMERO_DE_PROJET.REGION.run.app
```

Le bloc de chiffres colle au nom a la fin n'est **pas** le nom du service, c'est
le numero de projet Google. `mon-service-915091828554.europe-west1.run.app`
veut dire : service `mon-service`, projet `915091828554`, region `europe-west1`.
Recopier l'adresse entiere comme nom de service cree un second service
(`mon-service-915091828554`) et laisse le vrai intact — donc muet, ou bloque
sur une page de bienvenue.

C'est le piege numero un, parce qu'il est silencieux :

- un service cree depuis la console (echantillon « Hello World ») garde **son** nom,
  donc **son** contenu, pour toujours ;
- ton deploiement part sur le service nomme dans ce fichier ;
- l'URL que tu ouvres dans le navigateur peut donc etre celle du service jamais
  remplace — celui qui affiche encore une page de bienvenue nginx.

```
gcloud run services list --region europe-west1
```

Lis la colonne URL et la colonne SERVICE. Si le service dont tu ouvres l'URL n'est
pas exactement `the-evil-cloud-03`, tu compares deux choses differentes : redeploie
sous le nom du service que tu veux vraiment utiliser, ou ouvre l'URL du service
`the-evil-cloud-03`. Tant que les deux ne coincident pas, tout ce que tu vois a
l'ecran vient de l'autre conteneur.

## Verifier que le conteneur vit

```
curl -i https://the-evil-cloud-03-xxxxx.europe-west1.run.app/healthz
```

`200 ok` → les deux processus tournent. `502` / `503` → regarde les logs :
le plus souvent une erreur de syntaxe dans `config.json` ou `nginx.conf`.

La racine `/` renvoie aussi un marqueur : `dgm-cloud-run-stack | service=… | nodes=N`.
Si tu vois autre chose (une page de bienvenue nginx, un 404 nu), c'est la preuve
que la revision qui repond n'est PAS ce depot — voir la section suivante.

```
curl -i https://the-evil-cloud-03-xxxxx.europe-west1.run.app/🦋🐉
```

Un `400` / `403` sur un chemin de nœud est **normal** avec un client HTTP nu :
c'est la poignée de main WebSocket qui échoue, donc le nœud est bien vivant.

## Rendre le service utilisable

```
gcloud run services update the-evil-cloud-03 --region europe-west1 --min-instances 1
```

Sans ça, le conteneur s'éteint quand personne ne s'en sert et met 3 à 10 s à
revenir. La plupart des clients abandonnent à 8 s : la première connexion de la
journée échoue sur un serveur parfaitement sain.

## Repartir de zéro, sans rien perdre

À faire quand la sonde montre que le conteneur ne sert pas les nœuds du
panneau (protocoles manquants, chemins inconnus, ou `404` sur
`/stack.json`). Aucune identité n'est perdue : le parc vit dans le panneau,
pas dans le conteneur. On écrase donc le dépôt sans risque.

1. **Panneau → Exporter le parc** : garde le fichier JSON de côté. C'est la
   seule sauvegarde des UUID et des chemins — vider le cache du navigateur
   les effacerait pour de bon.
2. **Panneau → Télécharger le .zip** (le bouton rose, en haut), puis
   **décompresse-le** sur ton PC.
3. **GitHub → ton dépôt → Add file → Upload files**, glisse **le contenu** du
   dossier décompressé (Dockerfile, config.json, nginx.conf, entrypoint.sh,
   watchdog.sh, expiry.txt, README.md — jamais le dossier lui-même).
   Les fichiers de même nom sont remplacés : c'est voulu.
4. **Recrée `.github/workflows/deploy.yml` à la main** (Add file → Create new
   file, chemin complet). Le glisser-déposer jette `.github` en silence.
5. **Cloud Run → ton service → Déployer une révision → Depuis un dépôt /
   source**, ou dans Cloud Shell : `gcloud run deploy NOM_DU_SERVICE --source .`.
   Vérifie le NOM du service : s'il diffère d'un caractère, Google crée un
   SECOND service et laisse celui que tu ouvres inchangé.
6. **Appelle `/stack.json`** et vérifie que `protocols` contient bien les
   trois protocoles, puis que le chemin du nœud qui refuse y est.
7. **Re-teste un nœud VMess ou Trojan en premier** : c'est celui qui tombe
   quand le déploiement est en retard, donc le meilleur témoin.

Si `/stack.json` renvoie `Welcome to nginx!`, l'URL que tu ouvres pointe sur
l'échantillon créé par la console, pas sur ce dépôt : compare

`gcloud run services list --region ${region}` avec l'URL de ton navigateur.

## Couper le service pour de vrai

`control.env` porte l'adresse du Backend et le jeton de CE serveur. Toutes les
20 secondes, `watchdog.sh` demande son etat :

- `on` : tout sert normalement ;
- `pause` : tous les chemins de noeuds repondent `503` (`/healthz` repond
  toujours, donc Cloud Run ne s'inquiete pas) ;
- `off` : le conteneur s'arrete. Cloud Run le relance, il relit l'etat et
  s'arrete de nouveau : le service est reellement coupe.

Depuis le panneau, les boutons « Tout couper » et « Tout en pause » ecrivent
cet etat. Aucun compte Google a ouvrir, aucun fichier a recoller, aucun
redeploiement.

Si `control.env` est vide, le conteneur ignore le panneau et sert normalement.

## Les limites à connaître

- **1 Go** de trafic sortant offert par mois, puis facturé au Go.
- **60 minutes** maximum par connexion.
- **Aucun UDP** : pas de QUIC, pas d'Hysteria, pas de WireGuard, pas de SSH.
- **90 nœuds** maximum dans ce conteneur (un port local par nœud).
- **512 Mo** conseillés dès qu'il y a plus d'une dizaine de nœuds.

## Sécurité

`config.json` contient toutes les identités du service, et `expiry.txt` leurs
échéances. Garde le dépôt **privé**. S'il passe en public, fais tourner toutes
les identités et redéploie dans la même minute.

## Rappel côté client

| Champ | Valeur |
|---|---|
| Adresse | l'URL run.app du service |
| Port | 443 |
| TLS / SNI | activé, SNI = l'URL run.app |
| Transport | ws |
| Host (en-tête WS) | l'URL run.app, dans le paramètre host= du lien |
| Path | celui du nœud (voir le tableau plus haut) |
| Identité | celle du nœud (UUID, ou mot de passe en Trojan) |