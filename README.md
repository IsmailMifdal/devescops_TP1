# DevSecOps TP1 & TP2 : Hardening Flask + PostgreSQL, build industriel et supply chain

> Auteur : **Ismail Mifdal** (monôme)

## 1. Packages GHCR publiés

| Package | URL |
|---|---|
| API Flask durcie | https://github.com/IsmailMifdal/devescops_TP1/pkgs/container/devescops_tp1 |

```bash
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.3.0   # version courante (immuable), index amd64 + arm64, signée
docker pull ghcr.io/ismailmifdal/devescops_tp1@sha256:25e106355d0bb67930b2a85a3a7dd8d38ae2462cd5b3c5adac2e38671d48e5f1   # même image, par digest
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.3     # dernier correctif de la 1.3
docker pull ghcr.io/ismailmifdal/devescops_tp1:1       # dernière version de la 1.x
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.0.0   # première release (amd64 seule)

# Le client choisit automatiquement l'architecture ; pour forcer :
docker pull --platform linux/arm64 ghcr.io/ismailmifdal/devescops_tp1:1.3.0
```

Test rapide de l'image publiée :

```bash
docker run --rm -p 127.0.0.1:5000:5000 ghcr.io/ismailmifdal/devescops_tp1:1.3.0
curl http://127.0.0.1:5000/health
```

Vérification de sa signature et de son SBOM : section 9, « Vérification publique pour l'évaluateur ».

| Version | Contenu |
|---|---|
| 1.0.0 | Première release durcie (amd64) |
| 1.1.0 | Correctifs des retours d'évaluation : mot de passe PostgreSQL en secret monté par fichier (`DB_PASSWORD_FILE`), politique Hadolint explicite, digests Chainguard renouvelés (4 CVE HIGH corrigées, Python 3.15). Image amd64 seule |
| 1.2.0 | Index multi-arch **linux/amd64 + linux/arm64** construit par Bake, cache BuildKit, secret de build en tmpfs (TP2, étape 1). Non signée |
| 1.3.0 | Couches identiques à la 1.2.0 (seuls les labels OCI, la provenance et donc les digests changent). Apports du TP2, étape 2 : SBOM CycloneDX + SPDX, audit Grype sur SBOM avec VEX, **signature keyless Cosign** de l'index et de chaque architecture, attestations SBOM et VEX, gate d'admission |

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

- **Permissions** : `permissions: {}` au niveau du workflow, chaque job ne reçoit que `contents: read`. Seul le job `release` obtient `packages: write` et `id-token: write` (jeton OIDC de la signature keyless), et uniquement sur un tag SemVer. La gate finale `verify` ne reçoit **aucune** permission.
- **Pinning SHA** : toutes les actions externes sont référencées par leur SHA de commit complet (version en commentaire). Un tag Git est modifiable, un SHA ne l'est pas : c'est exactement le vecteur utilisé lors de la compromission de `trivy-action` en mars 2026 (CVE-2026-33634).
- **Outils vérifiés** : Hadolint, Dive, Trivy, Syft, Grype et Cosign sont téléchargés en version fixe et contrôlés par `sha256sum -c` avant exécution. Ils sont installés hors du dépôt (`$RUNNER_TEMP`), pour ne pas être eux-mêmes analysés par `trivy fs`.
- **`persist-credentials: false`** sur les checkouts : le jeton n'est pas laissé sur le disque du runner.
- **Artefact unique** : l'image construite une seule fois est transmise aux jobs suivants ; c'est exactement cette image, scannée et testée, qui est publiée.
- **SemVer** : déclenchement sur tag `vX.Y.Z`. Tags publiés : `X.Y.Z` (immuable), `X.Y` et `X` (flottants pour suivre les correctifs), `sha-<commit>` (traçabilité). Pas de tag `latest`.

Pipeline (séquentiel, chaque étape bloquante) : `flake8` + `hadolint` → `build` (Bake multi-arch amd64/arm64, cache GHA, étanchéité du secret de build, Dive ≥ 80 %) → `security` (SBOM Syft, Trivy, Grype sur SBOM + VEX) → `integration` (Compose avec secret, contrôle d'exposition du mot de passe, /health, /dbtest, pytest) → `release` (GHCR, signature et attestations Cosign) → `verify` (gate d'admission). Détail en section 9.

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

## 9. TP2, étape 2 : SBOM, VEX, signature et gate d'admission

Fichiers concernés : [.grype.yaml](.grype.yaml), [security.vex.json](security.vex.json), [sbom.cdx.json](sbom.cdx.json), [sbom.spdx.json](sbom.spdx.json), [.github/workflows/ci-cd.yaml](.github/workflows/ci-cd.yaml).

### Correspondance avec les livrables du sujet

| Livrable ou section attendue | Où le trouver |
|---|---|
| `Dockerfile` (cache persistant, secret en mémoire vive) | Section 8, A et B |
| `docker-bake.hcl` (multi-arch, secret, versionnement, cache distribué) | Section 8, C |
| `sbom.cdx.json` et `sbom.spdx.json` | Racine du dépôt et artefacts CI `sbom`, `sbom-release-1.3.0`, `sbom-certifie-1.3.0` (ci-dessous, D) |
| `security.vex.json` et `.grype.yaml` | Racine du dépôt (ci-dessous, E) |
| `cosign.pub` | Sans objet : signature **keyless** OIDC. L'identité de vérification est documentée en F |
| Workflow complété | Ci-dessous, « Pipeline final » |
| Preuves BuildKit : chronométrage froid/chaud, absence du jeton, manifeste amd64 + arm64 | Section 8, « Preuves d'exécution » et « Preuves CI et publication GHCR » |
| Requêtes JSON sur le SBOM et justification VEX | Ci-dessous, D et E |
| Commandes de vérification pour l'évaluateur | Ci-dessous, « Vérification publique » |

### D. SBOM CycloneDX et SPDX

- **Outil** : Syft 1.54.1, analyse **statique** du système de fichiers de l'image. Le conteneur n'est jamais exécuté.
- **Deux standards** : CycloneDX 1.6 JSON (OWASP, orienté sécurité, porte nativement le VEX) et SPDX 2.3 JSON (ISO/IEC 5962:2021, orienté licences).
- **`SYFT_FILE_METADATA_SELECTION=none`** : le CycloneDX ne garde que les composants (39 entrées) au lieu de 1 902 entrées, dont 1 863 fichiers. Le SPDX conserve quand même la liste des fichiers de chaque paquet (`CONTAINS`), d'où sa taille (1,6 Mo indenté, contre 169 Ko pour le CycloneDX).
- **Trois générations, trois garanties** :

| Où | Source analysée | Rôle |
|---|---|---|
| Job `security` | Images testées `api:ci` (amd64) et `api:ci-arm64`, lues dans le démon Docker | SBOM audité par Grype ; artefact `sbom` (90 jours) |
| Job `release` | Images publiées, relues **dans le registre par digest** | Comparé au SBOM testé (mêmes PURL, sinon échec), puis attesté ; artefact `sbom-release-<version>` |
| Job `verify` | Attestations signées du registre | SBOM **certifié** extrait après vérification ; artefact `sbom-certifie-<version>` |

`sbom.cdx.json` et `sbom.spdx.json`, à la racine, sont les SBOM certifiés de l'index `1.3.0`, extraits de leur attestation (section « Vérification publique », étape 3).

**Interrogation programmatique** (mêmes requêtes que le job `security`, résultats sur `1.3.0`) :

```
$ jq '.components | length' sbom.cdx.json
39
$ jq -r '[.components[].purl // empty | split("/")[0]] | group_by(.) | map("\(.[0]) : \(length)") | .[]' sbom.cdx.json
pkg:apk : 30
pkg:pypi : 8
$ jq -r '.components[] | select(.purl // "" | startswith("pkg:pypi/")) | "\(.purl) [\([.licenses[]? | .license.id // .license.name] | join(", "))]"' sbom.cdx.json
pkg:pypi/blinker@1.9.0 [MIT]
pkg:pypi/click@8.5.0 [BSD-3-Clause]
pkg:pypi/flask@3.1.3 [BSD-3-Clause]
pkg:pypi/itsdangerous@2.2.0 [BSD-3-Clause]
pkg:pypi/jinja2@3.1.6 []
pkg:pypi/markupsafe@3.0.4 [BSD-3-Clause]
pkg:pypi/psycopg2-binary@2.9.13 [LGPL with exceptions]
pkg:pypi/werkzeug@3.1.9 [BSD-3-Clause]
$ jq -r '[.components[].licenses[]? | .license.id // .license.name // .expression] | unique | .[]' sbom.cdx.json
Apache-2.0
BSD-2-Clause
BSD-2-Clause AND GPL-2.0-only
BSD-3-Clause
GPL-3.0-or-later
GPL-3.0-or-later AND GPL-2.0-or-later AND GPL-2.0-only AND GPL-1.0-only AND LGPL-2.1-or-later AND BSD-1-Clause AND BSD-2-Clause AND BSD-3-Clause AND BSD-4-Clause-UC AND MIT AND CC-PDDC
GPL-3.0-or-later WITH GCC-exception-3.1
LGPL with exceptions
LGPL-2.1-or-later
MIT
MPL-2.0 AND MIT
PSF-2.0
blessing
$ jq -r '.components[] | select((.licenses // []) | length == 0) | "\(.type) \(.name) \(.version)"' sbom.cdx.json
library jinja2 3.1.6
operating-system wolfi 20230201
$ jq '(.packages | length), (.files | length)' sbom.spdx.json
39
1863
$ jq -r '[.packages[].licenseDeclared] | group_by(.) | map("\(length) \(.[0])") | .[]' sbom.spdx.json
1 (BSD-2-Clause AND GPL-2.0-only)
1 (GPL-3.0-or-later AND GPL-2.0-or-later AND GPL-2.0-only AND GPL-1.0-only AND LGPL-2.1-or-later AND BSD-1-Clause AND BSD-2-Clause AND BSD-3-Clause AND BSD-4-Clause-UC AND MIT AND CC-PDDC)
2 (GPL-3.0-or-later WITH GCC-exception-3.1)
3 (MPL-2.0 AND MIT)
3 Apache-2.0
1 BSD-2-Clause
4 BSD-3-Clause
3 GPL-3.0-or-later
3 LGPL-2.1-or-later
1 LicenseRef-LGPL-with-exceptions
9 MIT
4 NOASSERTION
3 PSF-2.0
1 blessing
```

**Lecture du SBOM**

- **Composition** : 8 bibliothèques Python (dont 2 transitives non importées directement : `blinker`, `markupsafe`), 30 paquets Wolfi (interpréteur `python-3.15`, `glibc`, `openssl-4.0`, `ca-certificates-bundle`, la roue inerte `py3-pip-wheel`…) et le système d'exploitation `wolfi`. Ni shell, ni gestionnaire de paquets, ni compilateur.
- **`jinja2` sans licence** : c'est un *known unknown* au sens des éléments minimaux CISA. La licence amont est BSD-3-Clause, mais elle n'est pas déclarée dans les métadonnées installées. Syft l'exporte donc en `NOASSERTION` côté SPDX.
- **`psycopg2-binary` : licence non SPDX** (« LGPL with exceptions », exportée en `LicenseRef-LGPL-with-exceptions`). La LGPL est compatible avec notre usage : liaison dynamique, aucune modification du code.
- **Copyleft** : les GPL ne concernent que des bibliothèques système Wolfi (`readline`, `gdbm`, `xz`, `libuuid`, `libzstd1`) et `libgcc`/`libstdc++` sous exception GCC. Elles sont utilisées telles quelles par liaison dynamique. Aucune AGPL.
- **Limites** : les paquets PyPI n'ont pas d'empreinte (`hashes`) dans le SBOM. C'est une limite de Syft sur un venv déjà installé.

### E. Audit du SBOM par Grype et qualification VEX

**Politique** ([.grype.yaml](.grype.yaml)) :

| Clé | Valeur | Effet |
|---|---|---|
| `fail-on-severity` | `high` | Code retour 1 dès qu'une vulnérabilité HIGH ou CRITICAL subsiste |
| `only-fixed` | `true` | Seules les vulnérabilités **avec correctif publié** comptent pour la porte |
| `vex-documents` | `security.vex.json` | Les déclarations OpenVEX sont appliquées à chaque scan |
| `ignore` | `[]` | Aucune exclusion opaque : toute exemption passe par le VEX |
| `show-suppressed` | `true` | Une vulnérabilité neutralisée reste affichée (traçabilité) |

Grype analyse le **fichier SBOM** (`grype sbom:sbom/sbom.cdx.json -c .grype.yaml`), pas l'image : pas de nouveau téléchargement ni de décompression des couches. Trivy continue de scanner les images (vulnérabilités et secrets) : deux moteurs, deux bases de données.

**Constat (base Grype du 29/10/2026)**

| Moteur | Résultat sur l'image (toutes sévérités, sans filtre) |
|---|---|
| Trivy 0.75.0 | 0 vulnérabilité (amd64 et arm64) |
| Grype 0.120.1 | 1 vulnérabilité : `CVE-2026-114583`, `python-3.15 3.15.0_git20261017-r4`, Medium, aucun correctif Wolfi, EPSS 0,23 % (amd64 et arm64) |

**Analyse de CVE-2026-114583** : `tarfile.tar_filter` peut être contourné par des liens forgés. Une archive malveillante, extraite avec `tarfile.extractall(filter="tar")`, peut alors écrire hors du répertoire cible.

1. **Le code vulnérable est-il présent ?** Oui. Le correctif CPython de la branche 3.15 ([`c6ada40`](https://github.com/python/cpython/commit/c6ada40177436e4e2533a7b252082b5f0c043477)) date du 22/10, après le snapshot Wolfi du 17/10. Vérification dans l'image :
   ```
   $ docker run --rm --entrypoint python ghcr.io/ismailmifdal/devescops_tp1:1.2.0 -c "…"
   python 3.15.0 | /usr/lib/python3.15/tarfile.py
   correctif present (normpath(name) == os.curdir) : False
   ancien controle present (target_path == dest_path) : True
   ```
   La justification `vulnerable_code_not_present` serait donc **fausse**.
2. **Le code vulnérable est-il exécuté ?** Non. `app.py` n'importe que `flask`, `psycopg2` et `os`. L'API n'expose aucun envoi de fichier et n'extrait aucune archive. Preuve dynamique dans l'image : l'application est chargée, puis ses deux routes sont appelées.
   ```
   /health -> 200
   /dbtest -> 500 (sans base : erreur attendue)
   modules charges : 369
   tarfile charge : False | shutil charge : True
   fichiers des dependances qui mentionnent tarfile : aucun
   ```
3. **Exploitabilité** : vecteur local (CVSS 4.0 `AV:L`), EPSS 0,23 % (13e centile).

**Décision** : `not_affected` avec la justification normalisée **`vulnerable_code_not_in_execute_path`** ([security.vex.json](security.vex.json)).

- **Produit visé** : le PURL du paquet, `pkg:apk/wolfi/python-3.15@3.15.0_git20261017-r4`, sans qualificateur `arch`. La déclaration couvre donc amd64 et arm64.
- **Échéance** : la `status_notes` prévoit de retirer l'exemption dès que l'image de base embarquera Python ≥ 3.15.2.
- **Point métier** : un VEX sert à qualifier, pas à cacher. La vulnérabilité reste visible dans chaque rapport, marquée comme neutralisée.

**Effet mesuré** (mêmes commandes que la CI) :

```
# Sans VEX : la vulnérabilité est active
$ grype sbom:sbom.cdx.json
NAME         INSTALLED              TYPE  VULNERABILITY    SEVERITY  EPSS         RISK
python-3.15  3.15.0_git20261017-r4  apk   CVE-2026-114583  Medium    0.2% (13th)  0.1

# Avec VEX : elle est neutralisée, de façon auditable
$ grype sbom:sbom.cdx.json --vex security.vex.json --show-suppressed
NAME         INSTALLED              TYPE  VULNERABILITY    SEVERITY  EPSS         RISK
python-3.15  3.15.0_git20261017-r4  apk   CVE-2026-114583  Medium    0.2% (13th)  0.1   (suppressed by VEX)

# Porte CI (.grype.yaml)
$ grype sbom:sbom.cdx.json -c .grype.yaml ; echo $?
0
```

**Gouvernance du VEX** : avant tout scan, un contrôle `jq` bloquant refuse le document dans trois cas :
- une déclaration sans `products`, ou dont le produit n'est pas un PURL ;
- un `not_affected` sans justification normalisée OpenVEX ou sans `impact_statement` ;
- un `affected` sans `action_statement`.

Ce contrôle vient d'un piège mesuré : **Grype ignore sans aucun message une déclaration sans `products`**. Les deux contre-épreuves sont rejetées (code retour 1) :
- déclaration sans `products` ;
- justification hors liste (`pas_de_risque`).

### F. Signature, attestations et gate d'admission

**Choix keyless (livrable 5)** : aucune paire de clés, donc pas de `cosign.pub`.

- Le job `release` obtient un jeton OIDC GitHub (`id-token: write`).
- Fulcio délivre un certificat éphémère au nom du workflow, et chaque signature est inscrite dans le journal de transparence public Rekor.
- Aucun secret n'est à stocker ni à faire tourner. Une signature n'est valide que si elle vient de **ce** workflow, de **ce** dépôt, pour **ce** tag.

Configuration de vérification d'identité :

| Paramètre | Valeur attendue |
|---|---|
| Émetteur OIDC (`--certificate-oidc-issuer`) | `https://token.actions.githubusercontent.com` |
| Identité (`--certificate-identity`) | `https://github.com/IsmailMifdal/devescops_TP1/.github/workflows/ci-cd.yaml@refs/tags/v1.3.0` |
| Contrôles supplémentaires en CI | dépôt `IsmailMifdal/devescops_TP1`, déclencheur `push`, SHA du commit du tag (`--certificate-github-workflow-*`) |

**Job `release`**, après la publication et le contrôle d'intégrité des couches :
1. Lecture des **digests immuables** : index, `linux/amd64`, `linux/arm64`.
2. SBOM des images **publiées**, lus dans le registre par digest, puis comparaison avec le SBOM testé et audité (mêmes PURL, sinon échec).
3. `cosign sign --recursive` sur le digest de l'index : l'index et chaque image sont signés. On signe un digest, jamais un tag mutable. Les tags `1.3`, `1` et `sha-…` désignent ce même index.
4. `cosign attest` (prédicats CycloneDX, SPDX et OpenVEX) :
   - chaque image reçoit **son** SBOM ;
   - l'index reçoit le SBOM de référence (amd64) et le VEX.
   `cosign attest` n'a pas d'option `--recursive` : chaque digest est attesté explicitement.

**Job `verify` (gate d'admission)** : il est indépendant, n'a **aucune permission**, n'utilise aucun identifiant pour lire le registre, et ne contient aucun `continue-on-error`.
1. Le tag `1.3.0` désigne toujours le digest signé.
2. `cosign verify` sur l'index et sur chaque image, avec l'identité exacte, l'émetteur, le dépôt, le déclencheur et le SHA du commit.
3. `cosign verify-attestation` CycloneDX, SPDX et OpenVEX. Le sujet in-toto de chaque attestation doit être le digest vérifié. Le SBOM certifié est ensuite extrait.
4. **Contre-épreuve** : une identité non autorisée (`…/forged.yaml@refs/heads/main`) doit être rejetée.

**Piège Cosign v3 découvert pendant la préparation.** Avec le nouveau format de bundle, `cosign verify` répond « OK » (code 0) sur une image **attestée mais jamais signée**. Il compte l'attestation comme une signature. Une gate qui ne testerait que le code retour serait trompée. Reproduction sur un registre local isolé d'Internet, avec une paire de clés jetable :

```
$ cosign verify --key cosign.pub reg:5000/witness2@sha256:46ae…   # attestée, NON signée
  - The signatures were verified against the specified public key   (exit 0)
1 ['https://cyclonedx.org/bom']
```

La gate exige donc en plus, sur le digest vérifié, une entrée de type `https://sigstore.dev/cosign/sign/v1` (signature d'image). Le contrôle `jq` renvoie `true` sur l'image signée et `false` (code 1) sur le témoin.

### Pipeline final

| # | Étape demandée | Job | Contrôles bloquants |
|---|---|---|---|
| 1 | Qualité et gouvernance statique | `flake8`, `hadolint` | Style Python, tests unitaires, Hadolint (dont `RUN --mount`) |
| 2 | Construction BuildKit et métrologie | `build` | Builder `docker-container` isolé, Bake amd64 + arm64, secret en tmpfs, absence du jeton (historique et couches), Dive ≥ 80 % |
| 3 | SBOM et double scan | `security` | VEX valide, Trivy images + dépôt, SBOM CycloneDX + SPDX (artefacts), Grype sur SBOM + VEX |
| 4 | Intégration sans shell | `integration` | PostgreSQL Chainguard épinglé par digest, sondes natives, `/health`, `/dbtest`, pytest |
| 5 | Publication, signature, attestation | `release` (tag uniquement) | Bake `--push`, couches identiques à l'image testée, SBOM publié = SBOM testé, signature et attestations par digest |
| 6 | Gate d'admission finale | `verify` (tag uniquement) | Signature et attestations revérifiées depuis le registre, contre-épreuve d'identité |

- Run sur `main` (jobs 1 à 4 verts, publication ignorée hors tag) : https://github.com/IsmailMifdal/devescops_TP1/actions/runs/40844184027
- Run de release `v1.3.0` (7/7 jobs verts du premier coup) : https://github.com/IsmailMifdal/devescops_TP1/actions/runs/40852353151

| Job | `main` | `v1.3.0` |
|---|---|---|
| Flake8 | 17 s | 11 s |
| Hadolint | 5 s | 7 s |
| Build multi-arch (Bake) et Dive | 64 s | 51 s |
| SBOM et double scan (Trivy + Grype/VEX) | 115 s | 115 s |
| Intégration Compose | 58 s | 60 s |
| Publication, signature et attestation | ignorée (hors tag) | 129 s |
| Gate d'admission | ignorée (hors tag) | 30 s |

Étapes des deux derniers jobs de la release :
```
success - Publication de l'index multi-arch (Bake, cache GHA du build validé)
success - Index OCI publié (amd64 + arm64)
success - Intégrité - les couches amd64 publiées sont celles de l'image testée
success - Digests immuables publiés (index + une image par architecture)
success - SBOM des images publiées, lus dans le registre par digest (Syft)
success - Le SBOM publié correspond au SBOM testé et audité (mêmes PURL)
success - Signature keyless (OIDC) de l'index et de chaque image, par digest
success - Attestations signées du SBOM (CycloneDX + SPDX) et du VEX, rattachées aux digests
success - Archiver les SBOM publiés et attestés (artefacts CI, 90 jours)
--- verify ---
success - Le tag SemVer désigne toujours le digest publié (lecture anonyme du registre)
success - Signature de l'index et de chaque image (Fulcio + Rekor)
success - Attestations SBOM et VEX authentiques, extraction du SBOM certifié
success - Contre-épreuve - une identité de signataire non autorisée est rejetée
success - Archiver le SBOM certifié extrait du registre
```

GHCR ne prend pas en charge l'API OCI *referrers* (`/v2/…/referrers/<digest>` renvoie 404). Cosign v3 se replie donc sur le schéma de tags `sha256-<digest>` : un tag par digest signé (index, amd64, arm64 et les deux manifestes d'attestation BuildKit) apparaît dans le package.

### Vérification publique pour l'évaluateur

Image publiée : `ghcr.io/ismailmifdal/devescops_tp1:1.3.0`

| Référence | Digest |
|---|---|
| Index multi-arch (tags `1.3.0`, `1.3`, `1`) | `sha256:25e106355d0bb67930b2a85a3a7dd8d38ae2462cd5b3c5adac2e38671d48e5f1` |
| `linux/amd64` | `sha256:556200632658fe6ba42a16a398cc9a888271f4970ea1f02982d8c84583ff4de4` |
| `linux/arm64` | `sha256:b29600fa703e683a311a3a06ae53ea35683aca709f9b2dfcb5738dfe27e2f1f3` |

Avec Cosign v3 installé, ou via Docker : `alias cosign='docker run --rm gcr.io/projectsigstore/cosign:v3.1.3'`. Aucune authentification n'est nécessaire.

```bash
IMAGE=ghcr.io/ismailmifdal/devescops_tp1
DIGEST=sha256:25e106355d0bb67930b2a85a3a7dd8d38ae2462cd5b3c5adac2e38671d48e5f1
ID=https://github.com/IsmailMifdal/devescops_TP1/.github/workflows/ci-cd.yaml@refs/tags/v1.3.0
ISSUER=https://token.actions.githubusercontent.com

# 0. Le tag SemVer désigne bien l'index signé (amd64 + arm64)
docker buildx imagetools inspect "$IMAGE:1.3.0"

# 1. Signature de l'image (index ; même commande avec le digest amd64 ou arm64)
cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMAGE@$DIGEST" \
  | jq -r '.[].critical.type'          # doit contenir https://sigstore.dev/cosign/sign/v1

# 2. Attestation SBOM (CycloneDX ; --type spdxjson pour le SPDX, --type openvex pour le VEX)
cosign verify-attestation --type cyclonedx \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMAGE@$DIGEST" > att.jsonl

# 3. Extraction du SBOM certifié depuis l'attestation vérifiée
jq -r '.payload' att.jsonl | head -n 1 | base64 -d > statement.json
jq -r '.predicateType, .subject[0].digest.sha256' statement.json   # https://cyclonedx.org/bom + digest de l'index
jq '.predicate' statement.json > sbom-certifie.cdx.json
jq '.components | length' sbom-certifie.cdx.json                  # 39
```

**Résultats obtenus depuis un poste sans authentification** (Cosign v3.1.3 en conteneur) :

```
$ cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMAGE@$DIGEST"
Verification for ghcr.io/ismailmifdal/devescops_tp1@sha256:25e106355d0bb67930b2a85a3a7dd8d38ae2462cd5b3c5adac2e38671d48e5f1 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
# types des entrées vérifiées sur l'index (exit 0, idem pour amd64 et arm64) :
https://spdx.dev/Document
https://cyclonedx.org/bom
https://sigstore.dev/cosign/sign/v1
https://openvex.dev/ns

# verify-attestation : 7 attestations, toutes en exit 0
att-cyclonedx-idx    https://cyclonedx.org/bom   sujet=25e106355d0b  39 composants
att-cyclonedx-amd64  https://cyclonedx.org/bom   sujet=556200632658  39 composants
att-cyclonedx-arm64  https://cyclonedx.org/bom   sujet=b29600fa703e  39 composants
att-spdxjson-idx     https://spdx.dev/Document   sujet=25e106355d0b  39 paquets
att-spdxjson-amd64   https://spdx.dev/Document   sujet=556200632658  39 paquets
att-spdxjson-arm64   https://spdx.dev/Document   sujet=b29600fa703e  39 paquets
att-openvex-idx      https://openvex.dev/ns      sujet=25e106355d0b  1 déclaration

# Extraction (étape 3) : ce sont les fichiers sbom.cdx.json et sbom.spdx.json de la racine
https://cyclonedx.org/bom
25e106355d0bb67930b2a85a3a7dd8d38ae2462cd5b3c5adac2e38671d48e5f1
39

# Contre-épreuve 1 : identité usurpée (exit 1)
$ cosign verify --certificate-identity "https://github.com/IsmailMifdal/devescops_TP1/.github/workflows/forged.yaml@refs/heads/main" …
failed to verify certificate identity: no matching CertificateIdentity found, last error: expected SAN value
"https://github.com/IsmailMifdal/devescops_TP1/.github/workflows/forged.yaml@refs/heads/main",
got "https://github.com/IsmailMifdal/devescops_TP1/.github/workflows/ci-cd.yaml@refs/tags/v1.3.0"

# Contre-épreuve 2 : la 1.2.0, publiée avant l'étape 2, n'est pas signée (exit 10)
$ cosign verify … ghcr.io/ismailmifdal/devescops_tp1:1.2.0
error during command execution: no signatures found
```

**Limites et niveau atteint**

- **Niveau SLSA** : la signature Cosign, la provenance BuildKit (manifestes `attestation-manifest` de l'index) et la construction sur un runner GitHub éphémère amènent la chaîne au niveau **SLSA Build L2**. Le niveau L3 exigerait un générateur de provenance isolé du job de build (`slsa-github-generator`).
- **SBOM de l'index** : l'attestation de l'index porte le SBOM amd64, l'image de référence testée. Les compositions amd64 et arm64 sont identiques au qualificateur `arch` près des PURL, et chaque image porte de toute façon son propre SBOM.

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
