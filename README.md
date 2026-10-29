# DevSecOps TP1 : Hardening Flask + PostgreSQL

> Auteur : **Ismail Mifdal** (monôme)

## 1. Packages GHCR publiés

| Package | URL |
|---|---|
| API Flask durcie | https://github.com/IsmailMifdal/devescops_TP1/pkgs/container/devescops_tp1 |

```bash
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.2.0   # version courante (immuable), index amd64 + arm64
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.2     # dernier correctif de la 1.2
docker pull ghcr.io/ismailmifdal/devescops_tp1:1       # dernière version de la 1.x
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.0.0   # première release (amd64 seule)

# Le client choisit automatiquement l'architecture ; pour forcer :
docker pull --platform linux/arm64 ghcr.io/ismailmifdal/devescops_tp1:1.2.0
```

Test rapide de l'image publiée :

```bash
docker run --rm -p 127.0.0.1:5000:5000 ghcr.io/ismailmifdal/devescops_tp1:1.2.0
curl http://127.0.0.1:5000/health
```

| Version | Contenu |
|---|---|
| 1.0.0 | Première release durcie (amd64) |
| 1.1.0 | Correctifs des retours d'évaluation : mot de passe PostgreSQL en secret monté par fichier (`DB_PASSWORD_FILE`), politique Hadolint explicite, digests Chainguard renouvelés (4 CVE HIGH corrigées, Python 3.15). Image amd64 seule |
| 1.2.0 | Index multi-arch **linux/amd64 + linux/arm64** construit par Bake, cache BuildKit, secret de build en tmpfs (TP2, étape 1) |

## 2. Comparatif Avant / Après

| Critère | Avant (`python:3.10-slim`) | Après (Chainguard Python) |
|---|---|---|
| Poids de l'image | 148 Mo | 88,5 Mo |
| Utilisateur d'exécution | `root` | `65532` (nonroot) |
| Shell présent | Oui (`/bin/sh`, `bash`) | Non |
| Gestionnaire de paquets / pip | Oui (`apt`, `pip`) | Non |
| CVE Trivy (toutes sévérités) | 185 (47 HIGH, 73 MEDIUM, 63 LOW, 2 UNKNOWN) | 0 |
| CVE Trivy HIGH/CRITICAL corrigibles | 3 | 0 |
| CVE Python (`requirements.txt`) | 19 entrées / 3 paquets | 0 |
| Efficience Dive | 97,35 % (5,7 Mo gaspillés) | 99,72 % (251 ko gaspillés) |
| Base PostgreSQL | `postgres:14-alpine` (tag mouvant) | `cgr.dev/chainguard/postgres` épinglée par digest |
| Mot de passe BDD | En clair dans `docker-compose.yml` (`testpass`) et en dur dans `app.py` | Secret Compose monté par fichier, absent de toute variable d'environnement |
| Politique Hadolint | Aucune | 25 règles explicites, toutes bloquantes |

## 3. Images de base retenues

**API** : `cgr.dev/chainguard/python`, en deux variantes de la même famille :

- `latest-dev` pour l'étage `builder` : contient `pip` et un shell, nécessaires pour créer le venv. Cet étage n'est jamais livré.
- `latest` pour l'étage `runtime` : uniquement l'interpréteur Python et ses bibliothèques, sans shell, sans gestionnaire de paquets, sans compilateur, utilisateur non-root par défaut.

Chainguard a été préféré à Distroless car ses images sont reconstruites en continu à partir de Wolfi (correctifs CVE rapides), signées, fournies avec un SBOM, et la paire `-dev`/runtime garantit la même version de Python entre construction et exécution.

**Base de données** : `cgr.dev/chainguard/postgres`, image minimale durcie compatible avec les variables `POSTGRES_*` de l'image officielle.

**Immuabilité et reproductibilité** : l'offre gratuite Chainguard ne publie que le tag `latest`. Toutes les images sont donc épinglées par **digest SHA256** (`image:latest@sha256:...`) : le digest identifie un contenu unique et immuable, le tag n'est plus qu'une annotation. Les dépendances Python sont épinglées en `==` sur l'arbre complet. Les outils CI (Hadolint, Dive, Trivy) sont téléchargés en version fixe et vérifiés par SHA256.

**Renouvellement des digests** : un digest figé ne reçoit plus de correctifs ; c'est le scan Trivy bloquant qui déclenche sa mise à jour. Exemple réel : 18 jours après la v1.0.0, Trivy a signalé 4 CVE HIGH corrigeables dans la base (`ca-certificates-bundle` CVE-2026-111943, `libbrotlicommon1` CVE-2026-111497). Les digests `python:latest` et `python:latest-dev` ont été renouvelés ensemble, ce qui garantit la même version de Python (3.15.0) dans les deux étages. Le venv construit dans l'un reste donc exécutable dans l'autre. Le digest PostgreSQL a été renouvelé dans la même version majeure (18.6), ce qui garde le volume de données compatible.

## 4. Healthchecks sans shell

Dans une image sans shell, `CMD-SHELL` et `curl`/`wget` sont indisponibles. Les deux sondes utilisent la forme exec `["CMD", ...]`, exécutée directement par le runtime de conteneurs.

- **API** : `["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"]`. On réutilise l'interpréteur déjà présent et sa bibliothèque standard. `urlopen` lève une exception (code retour 1) sur erreur réseau ou statut HTTP d'erreur.
- **PostgreSQL** : `["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "<user>", "-d", "<db>"]`, utilitaire client fourni dans l'image. `-h 127.0.0.1` force une connexion TCP : pendant l'initialisation, le serveur temporaire n'écoute que sur le socket local, la sonde ne passe donc au vert qu'une fois le vrai serveur prêt.
- **Synchronisation** : `depends_on: condition: service_healthy` empêche l'API de démarrer avant que PostgreSQL soit sain ; en CI, `docker compose up --wait --wait-timeout 120` attend l'état sain des deux services avec un délai maîtrisé.

### Mot de passe PostgreSQL : secret monté par fichier

Une variable d'environnement n'est pas un coffre : elle se lit avec `docker inspect`, dans `/proc/<pid>/environ` et dans `docker compose config`, et elle est héritée par tous les processus enfants. Le mot de passe ne transite donc plus par l'environnement :

```yaml
secrets:
  db_password:
    file: ./secrets/db_password.txt     # non versionné (.gitignore), exclu du contexte de build (.dockerignore)

services:
  db:
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password   # lu par file_env dans l'entrypoint Chainguard
    secrets: [db_password]
  api-python:
    environment:
      DB_PASSWORD_FILE: /run/secrets/db_password          # lu par read_secret() dans app.py
    secrets: [db_password]
```

- Seuls les services qui déclarent `secrets: [db_password]` (base, API, tests) voient le fichier, monté en lecture seule dans `/run/secrets/`.
- Côté API, `read_secret("DB_PASSWORD")` lit `DB_PASSWORD_FILE` et ne garde `DB_PASSWORD` qu'en repli. Le mot de passe par défaut `testpass`, codé en dur, a été supprimé.
- Côté PostgreSQL, l'entrypoint de l'image Chainguard applique la convention `*_FILE` (fonction `file_env`), comme l'image officielle.
- Le `.env` ne contient plus que des valeurs non sensibles (`POSTGRES_USER`, `POSTGRES_DB`).
- En CI, le secret est un fichier éphémère : `openssl rand -hex 24`, mode `0444`, supprimé au teardown. Un secret `file` hors Swarm est un bind mount qui garde le mode de l'hôte, d'où la lecture ouverte aux UID non-root des conteneurs (postgres et 65532). Une étape bloquante vérifie avec `docker inspect` que le mot de passe n'apparaît dans l'environnement d'aucun conteneur.

Autres durcissements Compose : réseau `backend` en `internal: true` (base injoignable depuis l'hôte et Internet, port 5432 non publié), API publiée uniquement sur `127.0.0.1`, système de fichiers de l'API en lecture seule, `cap_drop: ALL`, `no-new-privileges`.

## 5. Journal des remédiations

### Qualité (Flake8)

Le code passait la configuration fournie uniquement grâce aux règles ignorées. Sans ces exclusions, 11 violations étaient masquées, toutes corrigées sans modifier la logique :

| Fichier | Règle | Occurrences | Correction |
|---|---|---|---|
| app.py | E302 (2 lignes vides attendues) | 4 | Lignes ajoutées |
| app.py | W293 (espaces sur ligne vide) | 1 | Espaces supprimés |
| app.py | W391 (ligne vide en fin de fichier) | 1 | Supprimée |
| test_app.py | E302 | 4 | Lignes ajoutées |
| test_app.py | W292 (pas de saut de ligne final) | 1 | Ajouté |

Le marqueur `integration` est déclaré dans `pytest.ini` (supprime l'avertissement `PytestUnknownMarkWarning`).

### Gouvernance Hadolint

`.hadolint.yaml` fixe le seuil d'échec à `warning`, n'autorise aucune dérogation (`ignored: []`) et liste **explicitement** chaque règle de la politique d'équipe avec sa sévérité. On ne dépend plus des sévérités par défaut de l'outil, qui peuvent changer d'une version à l'autre.

| Sévérité | Règle | Exigence |
|---|---|---|
| error | DL3002 | Dernier `USER` non root |
| error | DL3006, DL3007 | Pas d'image sans tag, pas de `:latest` sans digest |
| error | DL4006 | `SHELL -o pipefail` avant tout `RUN` avec pipe |
| error | DL3026 | Registres limités à docker.io, gcr.io, cgr.dev, ghcr.io |
| error | DL3004 | Pas de `sudo` |
| warning | DL3025, DL4003, DL4004 | `CMD`/`ENTRYPOINT` en forme JSON exec, une seule instance |
| warning | DL3042, DL3013 | `pip --no-cache-dir`, versions épinglées |
| warning | DL3020, DL3021, DL3045 | `COPY` explicite plutôt que `ADD`, destinations non ambiguës |
| warning | DL3022, DL3023, DL3024 | `COPY --from` vers un étage déclaré, alias uniques |
| warning | DL3000, DL3003 | `WORKDIR` absolu, pas de `cd` |
| warning | SC2086, SC2046 | Variables et substitutions entre guillemets |
| warning | SC2164, SC2155 | `cd ... \|\| exit`, codes retour non masqués |
| warning | DL4000 | Pas de `MAINTAINER` |

Point notable : **SC2086** (variable non protégée) est au niveau `info` par défaut dans Hadolint. Avec un simple `failure-threshold: warning`, elle passerait donc sans bloquer. La politique la rehausse explicitement en `warning`.

La politique a été testée sur deux Dockerfiles volontairement fautifs : chacune des 25 règles est levée et le code retour vaut 1 (voir les preuves en section 7).

### Dépendances Python

| Paquet | Version initiale | Vulnérabilités | Version retenue |
|---|---|---|---|
| Flask | 2.3.2 | CVE-2026-27205 | 3.1.3 |
| Werkzeug | 2.3.3 | CVE-2023-46136, CVE-2024-34069, CVE-2024-49766, CVE-2024-49767, CVE-2025-66221, CVE-2026-21860, CVE-2026-27199, GHSA-g6x2-hccm-hh4m | 3.1.9 |
| pytest | 7.4.0 | CVE-2025-71176 | 9.1.1 (déplacé en dev) |
| psycopg2-binary | non épinglé | Version non reproductible | 2.9.13 |

Choix :

- Montée vers les dernières versions stables, compatibles entre elles (Flask 3.1 exige Werkzeug ≥ 3.1).
- Arbre complet épinglé (dépendances transitives incluses) pour des builds reproductibles.
- `pytest` sorti de `requirements.txt` vers `requirements-dev.txt` : un outil de test n'a rien à faire dans l'image de production.
- Compatibilité validée : `pytest` (dont `test_dbtest` contre PostgreSQL) passe avec les nouvelles versions.
- Audit : `pip-audit` / `trivy fs` sur le nouveau manifeste : 0 vulnérabilité connue.

## 6. Sécurisation de la chaîne CI/CD

- **Permissions** : `permissions: {}` au niveau du workflow, chaque job ne reçoit que `contents: read`. Seul le job `release` obtient `packages: write`, et uniquement sur un tag SemVer.
- **Pinning SHA** : toutes les actions externes sont référencées par leur SHA de commit complet (version en commentaire). Un tag Git est modifiable, un SHA ne l'est pas : c'est exactement le vecteur utilisé lors de la compromission de `trivy-action` en mars 2026 (CVE-2026-33634).
- **Outils vérifiés** : Hadolint, Dive et Trivy sont téléchargés en version fixe et contrôlés par `sha256sum -c` avant exécution.
- **`persist-credentials: false`** sur les checkouts : le jeton n'est pas laissé sur le disque du runner.
- **Artefact unique** : l'image construite une seule fois est transmise aux jobs suivants ; c'est exactement cette image, scannée et testée, qui est publiée.
- **SemVer** : déclenchement sur tag `vX.Y.Z`. Tags publiés : `X.Y.Z` (immuable), `X.Y` et `X` (flottants pour suivre les correctifs), `sha-<commit>` (traçabilité). Pas de tag `latest`.

Pipeline : `flake8` + `hadolint` → `build` (Bake multi-arch amd64/arm64, cache GHA, étanchéité du secret de build, Dive ≥ 80 %) → `security` (Trivy) + `integration` (Compose avec secret, contrôle d'exposition du mot de passe, /health, /dbtest, pytest) → `release` (GHCR).

## 7. Preuves d'exécution

Run GitHub Actions (toutes les barrières vertes sur `main`) : https://github.com/IsmailMifdal/devescops_TP1/actions/runs/37771793878

Les sorties ci-dessous sont celles des mêmes commandes que le pipeline, rejouées en local.

### Flake8
```
$ flake8 --config .flake8 .
$ echo $?
0
# Contre-vérification sans aucune règle ignorée
$ flake8 --isolated --max-line-length 88 app.py test_app.py
$ echo $?
0
```

### Hadolint
```
$ hadolint --config .hadolint.yaml Dockerfile
$ echo $?
0
```

Contre-épreuve : la politique appliquée à deux Dockerfiles volontairement fautifs (`hadolint v2.15.1`) lève chacune des 25 règles :
```
$ hadolint --config .hadolint.yaml Dockerfile.bad
:1 DL3026 error: Use only an allowed registry in the FROM image
:2 DL3006 error: Always tag the version of an image explicitly
:3 DL3024 warning: FROM aliases (stage names) must be unique
:3 DL3007 error: Using latest is prone to errors if the image will ever update. Pin the version explicitly to a release tag
:4 DL4000 warning: MAINTAINER is deprecated
:5 DL3045 warning: `COPY` to a relative destination without `WORKDIR` set.
:6 DL3000 warning: Use absolute WORKDIR
:7 DL3020 warning: Use COPY instead of ADD for files and folders
:8 DL3021 warning: COPY with more than 2 arguments requires the last argument to end with /
:9 DL3022 warning: `COPY --from` should reference a previously defined `FROM` alias
:10 DL3003 warning: Use WORKDIR to switch to a directory
:10 DL3004 error: Do not use sudo as it leads to unpredictable behavior. Use a tool like gosu to enforce root
:11 DL3013 warning: Pin versions in pip. [...]
:12 DL4006 error: Set the SHELL option -o pipefail before RUN with a pipe in it. [...]
:13 SC2046 warning: Quote this to prevent word splitting.
:14 SC2155 warning: Declare and assign separately to avoid masking return values.
:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
:16 DL4003 warning: Multiple `CMD` instructions found. [...]
:18 DL4004 warning: Multiple `ENTRYPOINT` instructions found. [...]
:19 DL3002 error: Last USER should not be root
$ echo $?
1

$ hadolint --config .hadolint.yaml Dockerfile.bad2
Dockerfile.bad2:3 DL3023 warning: `COPY --from` cannot reference its own `FROM` alias
Dockerfile.bad2:4 DL3042 warning: Avoid use of cache directory with pip. Use `pip install --no-cache-dir <package>`
Dockerfile.bad2:5 SC2086 warning: Double quote to prevent globbing and word splitting.
Dockerfile.bad2:6 SC2164 warning: Use 'cd ... || exit' or 'cd ... || return' in case cd fails.
Dockerfile.bad2:6 DL3003 warning: Use WORKDIR to switch to a directory
$ echo $?
1
```

### Dive (efficience ≥ 80 %)
```
$ CI=true dive --ci --lowestEfficiency=0.8 api:ci
  efficiency: 99.7170 %
  wastedBytes: 250844 bytes (251 kB)
  userWastedPercent: 0.5155 %
Results:
  PASS: highestUserWastedPercent
  SKIP: highestWastedBytes: rule disabled
  PASS: lowestEfficiency
Result:PASS [Total:3] [Passed:2] [Failed:0] [Warn:0] [Skipped:1]
```

### Trivy
```
$ trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed api:ci
│ api:ci (wolfi 20230201)                                     │   wolfi    │ 0 │
│ .../blinker-1.9.0.dist-info/METADATA                        │ python-pkg │ 0 │
│ .../click-8.5.0.dist-info/METADATA                          │ python-pkg │ 0 │
│ .../flask-3.1.3.dist-info/METADATA                          │ python-pkg │ 0 │
│ .../itsdangerous-2.2.0.dist-info/METADATA                   │ python-pkg │ 0 │
│ .../jinja2-3.1.6.dist-info/METADATA                         │ python-pkg │ 0 │
│ .../markupsafe-3.0.4.dist-info/METADATA                     │ python-pkg │ 0 │
│ .../psycopg2_binary-2.9.13.dist-info/METADATA               │ python-pkg │ 0 │
│ .../werkzeug-3.1.9.dist-info/METADATA                       │ python-pkg │ 0 │
$ echo $?
0

$ trivy fs --scanners vuln,secret --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed .
│ requirements.txt │ pip  │ 0 │ - │
```

Toutes sévérités confondues (`trivy image`, sans filtre) : 185 CVE sur l'image d'origine, 0 sur l'image durcie (v1.2.0, base Chainguard renouvelée).

### Compose : services sains
```
$ docker compose up -d --build --wait --wait-timeout 120
 Container devsecops-tp1-db-1 Healthy
 Container devsecops-tp1-api-python-1 Healthy
$ docker compose ps
NAME                         SERVICE      STATUS                  PORTS
devsecops-tp1-api-python-1   api-python   Up 6 seconds (healthy)  127.0.0.1:5000->5000/tcp
devsecops-tp1-db-1           db           Up (healthy)
$ curl -fsS http://127.0.0.1:5000/health
{"status":"ok"}
$ curl -fsS http://127.0.0.1:5000/dbtest
{"db_connection":"successful"}
```

### Secret PostgreSQL non exposé
```
$ docker compose config | grep -i password
      DB_PASSWORD_FILE: /run/secrets/db_password
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
$ docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' devsecops-tp1-api-python-1 | grep -i pass
DB_PASSWORD_FILE=/run/secrets/db_password
$ docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' devsecops-tp1-db-1 | grep -i pass
POSTGRES_PASSWORD_FILE=/run/secrets/db_password
# Le secret est bien appliqué par PostgreSQL : un mauvais mot de passe est refusé
$ docker compose exec -T api-python python -c "import psycopg2; psycopg2.connect(host='db', dbname='testdb', user='testuser', password='mauvais')"
FATAL:  password authentication failed for user "testuser"
```

### Tests d'intégration
```
$ docker compose --profile test run --rm tests
platform linux -- Python 3.15.0, pytest-9.1.1, pluggy-1.6.0 -- /app/venv/bin/python
collected 3 items

test_app.py::test_health PASSED                                          [ 33%]
test_app.py::test_hello PASSED                                           [ 66%]
test_app.py::test_dbtest PASSED                                          [100%]

============================== 3 passed in 0.82s ===============================
```

### Contrôles du runtime
```
$ docker run --rm --entrypoint sh api:ci -c true
exec: "sh": executable file not found in $PATH
$ docker run --rm --entrypoint python api:ci -c "import os; print(os.getuid())"
65532
$ docker run --rm --entrypoint python api:ci -c "import importlib.util as u; print(u.find_spec('pip'))"
None
```

### Publication GHCR
```
# Run de release sur le tag v1.0.0 (6/6 jobs verts, dont Publication GHCR) :
# https://github.com/IsmailMifdal/devescops_TP1/actions/runs/37772107773
$ docker pull ghcr.io/ismailmifdal/devescops_tp1:1.0.0
Digest: sha256:2da980f2aee00a38be9a1b2e48f9682402b489edb8fe8bb5024dc2a4d640bf09
Status: Downloaded newer image for ghcr.io/ismailmifdal/devescops_tp1:1.0.0
$ docker manifest inspect ghcr.io/ismailmifdal/devescops_tp1:1.0   # OK
$ docker manifest inspect ghcr.io/ismailmifdal/devescops_tp1:1     # OK
$ docker run --rm --entrypoint python ghcr.io/ismailmifdal/devescops_tp1:1.0.0 -c "import os; print('uid', os.getuid())"
uid 65532
```

## 8. TP2, étape 1 : build industriel, secrets de build et multi-arch

Fichiers concernés : [Dockerfile](Dockerfile), [docker-bake.hcl](docker-bake.hcl), [docker-compose.yml](docker-compose.yml), [.github/workflows/ci-cd.yaml](.github/workflows/ci-cd.yaml).

### A. Cache pip persistant hors couches

- **Syntaxe étendue explicite** : `# syntax=docker/dockerfile:1.27.1@sha256:4edf…` en tête du Dockerfile. C'est le frontend BuildKit qui apporte `RUN --mount`. Il est épinglé par digest comme les images de base, puisqu'il exécute lui aussi du code pendant le build.
- **Montage de cache dédié** : `--mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked`.
  - Le builder Chainguard `-dev` tourne en **non-root** (UID 65532, `HOME=/home/nonroot`). Le cache est donc monté à l'emplacement réel de pip, avec le bon propriétaire : un `target=/root/.cache/pip` n'aurait jamais servi.
  - `sharing=locked` sérialise l'accès quand amd64 et arm64 se construisent en parallèle.
  - Le cache vit dans le builder BuildKit, jamais dans une couche. `--no-cache-dir` n'est donc plus nécessaire.
- **Gouvernance intacte** : Hadolint reconnaît le montage de cache et ne lève pas DL3042, sans aucune dérogation. Sur un témoin sans montage ni `--no-cache-dir`, DL3042 est toujours levée (code retour 1).

### B. Jeton du dépôt interne : secret de build en mémoire vive

```dockerfile
RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    --mount=type=secret,id=pip_token,required=true,uid=65532,gid=65532,mode=0400 \
    if ! grep -q " /run/secrets/pip_token tmpfs " /proc/mounts; then … exit 1; fi \
    && if ! grep -Eq "^[A-Za-z0-9_-]{32,}$" /run/secrets/pip_token; then … exit 1; fi \
    && echo "Jeton du depot interne verifie (tmpfs, contenu non affiche)" \
    && pip --python /app/venv/bin/python install … -r requirements.txt
```

- **Pas d'`ARG` ni d'`ENV`.** Le jeton n'existe que dans `/run/secrets/pip_token`, le temps de ce `RUN`, puis il est démonté.
- **`required=true`** : le build échoue si le secret n'est pas fourni.
- **`uid=65532,mode=0400`** : le fichier est lisible par le seul utilisateur du build. Par défaut, il appartiendrait à root et resterait illisible.
- **Double vérification par le build** : le point de montage doit être de type `tmpfs` (mémoire vive) et le jeton doit avoir un format valide. Sinon, le build échoue.
- **Source du secret**
  - En local : `secrets/pip_token`, exclu par `.gitignore` (`secrets/`) et `.dockerignore` (liste blanche + `secrets`).
  - En CI : jeton éphémère `openssl rand -hex 32`, masqué dans les journaux (`::add-mask::`) et supprimé en fin de job.
- **Branchement** : Bake (`secret = ["id=pip_token,src=…"]`) et Compose (`build.secrets: [pip_token]`).

### C. Bake déclaratif et index multi-architecture

`docker-bake.hcl` remplace les lignes `docker buildx build` à rallonge :

| Élément | Valeur |
|---|---|
| Variables | `REGISTRY`, `IMAGE_NAME`, `VERSION`, `PLATFORMS`, `PIP_TOKEN_FILE`, `CACHE_BACKEND`, `CACHE_SCOPE`, toutes surchargeables par variable d'environnement |
| Architectures | `linux/amd64` (x86_64) et `linux/arm64` (ARM 64 bits) |
| Secret | `id=pip_token,src=${PIP_TOKEN_FILE}` |
| Cache externe | Import et export en `mode=max`. `gha` en CI (aucun droit `packages: write` en plus) ; `local` (`.buildx-cache`) sur poste de travail |
| Tags | Cible `docker-metadata-action`, redéfinie en release par `docker/metadata-action` (tags SemVer) |
| Cibles | `api` (index multi-arch), `api-local` (amd64 chargée dans Docker pour Dive, Trivy et Compose) |

Deux pièges évités :
- **Pas de `--load` en multi-arch.** Un index multi-arch ne peut pas être chargé dans un démon Docker classique (`overlay2`). Les contrôles s'appliquent donc à des variantes mono-architecture chargées depuis le même cache.
- **Pas d'export de cache depuis `api-local`.** Un export `gha` remplace l'index du `scope`. Si `api-local` exportait aussi, il effacerait le cache multi-arch dont la release a besoin.

### Pipeline CI/CD mis à jour

- **build**
  - Préparation : QEMU (`setup-qemu-action`), puis builder `docker-container` (`setup-buildx-action`).
  - `bake api` : construction amd64 + arm64, qui alimente le cache GHA en mode max.
  - `bake api-local` : variantes amd64 et arm64 chargées depuis ce cache.
  - Contrôle bloquant de l'étanchéité du jeton (historique `--no-trunc` et toutes les couches), puis Dive.
- **security** : Trivy (vulnérabilités **et secrets**) sur **chaque** architecture, plus `trivy fs`.
- **integration** : Compose, l'image de test est construite avec le secret de build monté.
- **release** (tag SemVer) : `bake api --push` avec les tags calculés par `metadata-action`. Le build est servi par le cache du build validé.
  - Deux contrôles bloquants après la publication : l'index publié est inspecté, et les couches (`diff_ids`) de l'image amd64 publiée doivent être **identiques** à celles de l'image testée.
- **Actions ajoutées**, épinglées par SHA (versions publiées depuis au moins deux semaines) :
  - `setup-qemu-action` v4.4.0
  - `setup-buildx-action` v4.4.1
  - `bake-action` v7.4.0 (la v7.5.0 était trop récente)

### Preuves d'exécution (local, builder `docker-container` BuildKit v0.33.1)

**Build multi-arch et cache**

| Scénario | Durée | Téléchargements pip |
|---|---|---|
| Build à froid, amd64 + arm64 | 228 s | Tous (arm64 réutilise déjà les roues « pures » téléchargées pour amd64) |
| Rebuild complet, cache chaud | 35 s | Aucun, 12 étapes `CACHED` |
| `click` 8.5.0 → 8.2.1 (une dépendance mineure modifiée) | 19 s | **`click` uniquement** |

```
$ docker buildx bake api-local --progress=plain      # requirements.txt : click==8.2.1
#15 [builder 4/5] COPY requirements.txt .
Jeton du depot interne verifie (tmpfs, contenu non affiche)
Using cached blinker-1.9.0-py3-none-any.whl (8.5 kB)
Downloading click-8.2.1-py3-none-any.whl (102 kB)
Using cached flask-3.1.3-py3-none-any.whl (103 kB)
Using cached itsdangerous-2.2.0-py3-none-any.whl (16 kB)
Using cached jinja2-3.1.6-py3-none-any.whl (134 kB)
Using cached markupsafe-3.0.4-cp315-cp315-manylinux2014_x86_64[…].whl (23 kB)
Using cached psycopg2_binary-2.9.13-cp315-cp315-manylinux2014_x86_64[…].whl (4.3 MB)
Using cached werkzeug-3.1.9-py3-none-any.whl (228 kB)
Successfully installed Flask-3.1.3 […] click-8.2.1 […]
```

**Aucun résidu de cache dans l'image finale** (88,5 Mo, Dive 99,72 %)
```
$ docker run --rm --entrypoint python api:ci -c "…"
repertoires de cache pip : aucun
/run/secrets/pip_token present : False
```
Le seul `.whl` présent, `/usr/share/python-wheels/pip-26.2.2-py3-none-any.whl`, appartient à l'image de base Chainguard (support de `venv`). Il ne vient pas du cache.

**Étanchéité du jeton** : images auditées par analyse octet par octet de chaque blob dans un conteneur Linux. L'étage `builder` est audité aussi, alors qu'il n'est jamais publié.
```
$ docker history --no-trunc api:ci | grep -F -f secrets/pip_token        -> 0 occurrence
$ docker history --no-trunc api:builder-audit | grep -F -f …               -> 0 occurrence
api_ci.tar            : 30 blobs analyses | occurrences du jeton = 0 | fichiers nommes pip_token = 0
api_builder-audit.tar : 32 blobs analyses | occurrences du jeton = 0 | fichiers nommes pip_token = 0
$ trivy image --scanners secret api:ci                 -> exit 0
$ trivy image --scanners secret api:builder-audit      -> exit 0
```
Contre-épreuve avec l'anti-pattern du cours (`ARG PIP_TOKEN`, jeton factice) : le même contrôle **détecte** la fuite.
```
ARG PIP_TOKEN=<JETON FACTICE EN CLAIR>
RUN |1 PIP_TOKEN=<JETON FACTICE EN CLAIR> /bin/sh -c echo "auth ok" > /tmp/marker # buildkit
leak.tar : 26 blobs analyses | occurrences du jeton = 1
```

**Le jeton n'entre ni dans le contexte de build ni dans git**
```
$ docker buildx build -f probe/Dockerfile .     # COPY . /ctx && find /ctx -type f
/ctx/app.py
/ctx/requirements-dev.txt
/ctx/requirements.txt
$ git check-ignore -v secrets/pip_token
.gitignore:9:secrets/   secrets/pip_token
```

**Index OCI multi-arch** (export `type=oci` de la cible `api`)
```
mediaType : application/vnd.oci.image.index.v1+json
  - linux/amd64      sha256:ae10cd06b758  (image)
  - linux/arm64      sha256:ae79c541d50d  (image)
  - unknown/unknown  sha256:5eb89df5eadf  (attestation-manifest)
  - unknown/unknown  sha256:72752abfe53d  (attestation-manifest)
```

**Exécution réelle de la variante arm64** (QEMU)
```
$ docker run --rm --platform linux/arm64 --entrypoint python api:arm64 -c "…"
machine = aarch64 | flask 3.1.3 | psycopg2 2.9.13
$ curl http://127.0.0.1:5055/health
{"status":"ok"}
```
Les roues natives `aarch64` de `psycopg2-binary` et `markupsafe` existent pour CPython 3.15 : aucune compilation sous émulation.

### Preuves CI et publication GHCR

- Run sur `main` (toutes les barrières vertes) : https://github.com/IsmailMifdal/devescops_TP1/actions/runs/40312096080
- Run de release `v1.2.0` (6/6 jobs verts) : https://github.com/IsmailMifdal/devescops_TP1/actions/runs/40316553701

| Job | `main` | `v1.2.0` |
|---|---|---|
| Flake8 | 11 s | 9 s |
| Hadolint | 5 s | 5 s |
| Build multi-arch (Bake) et Dive | 188 s | **66 s** (cache GHA chaud) |
| Trivy amd64 + arm64 | 37 s | 26 s |
| Intégration Compose | 63 s | 63 s |
| Publication GHCR multi-arch | ignorée (hors tag) | 51 s |

Étapes de la release, dont les deux contrôles bloquants qui suivent la publication :
```
success - Publication de l'index multi-arch (Bake, cache GHA du build validé)
success - Index OCI publié (amd64 + arm64)
success - Intégrité - les couches amd64 publiées sont celles de l'image testée
success - Purge du jeton éphémère
```

Index publié, inspecté depuis un poste sans authentification :
```
$ docker buildx imagetools inspect ghcr.io/ismailmifdal/devescops_tp1:1.2.0
Name:      ghcr.io/ismailmifdal/devescops_tp1:1.2.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:ed73e4e98ef88c81b81335b639ccf7af262a0e9cf9514a0e8e6074c347b88614
Manifests:
  Platform:    linux/amd64      @sha256:46ae2ae9c276645fab842f4c553ef67c22f2d510cc7e60db33b867825d281919
  Platform:    linux/arm64      @sha256:c85c02e50e0e121ca4ec6bab9bfdfb722c9cddf3df46af7c8d182bb7251a3dd3
  Platform:    unknown/unknown  (attestation-manifest -> amd64)
  Platform:    unknown/unknown  (attestation-manifest -> arm64)

tag 1.2         -> sha256:ed73e4e98ef88c81b81335b639ccf7af262a0e9cf9514a0e8e6074c347b88614
tag 1           -> sha256:ed73e4e98ef88c81b81335b639ccf7af262a0e9cf9514a0e8e6074c347b88614
tag sha-773723f -> sha256:ed73e4e98ef88c81b81335b639ccf7af262a0e9cf9514a0e8e6074c347b88614
```

Déploiement transparent sur les deux familles de processeurs (pull anonyme) :
```
$ docker run --rm --platform linux/amd64 --entrypoint python ghcr.io/ismailmifdal/devescops_tp1:1.2.0 -c "…"
x86_64 | uid 65532 | flask 3.1.3
$ docker run --rm --platform linux/arm64 --entrypoint python ghcr.io/ismailmifdal/devescops_tp1:1.2.0 -c "…"
aarch64 | uid 65532 | flask 3.1.3
```

## Lancer le projet en local

```bash
cp .env.example .env                       # valeurs non sensibles uniquement
mkdir -p secrets && openssl rand -hex 24 > secrets/db_password.txt
openssl rand -hex 32 > secrets/pip_token  # jeton simulé du dépôt interne (secret de build)
docker compose up -d --build --wait
curl http://127.0.0.1:5000/health
curl http://127.0.0.1:5000/dbtest
docker compose --profile test run --rm tests
docker compose --profile test down -v
```

Build multi-arch déclaratif (Bake) :

```bash
docker buildx create --name tp2-builder --driver docker-container --bootstrap
docker buildx bake --builder tp2-builder              # index amd64 + arm64 (cache local mode=max)
docker buildx bake --builder tp2-builder api-local    # variante amd64 chargée dans Docker (api:ci)
```
