# DevSecOps TP1 : Hardening Flask + PostgreSQL

> Binôme : **Ismail Mifdal** / **NOM 2**

## 1. Packages GHCR publiés

| Package | URL |
|---|---|
| API Flask durcie | https://github.com/IsmailMifdal/devescops_TP1/pkgs/container/devescops_tp1 |

```bash
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.0.0
docker pull ghcr.io/ismailmifdal/devescops_tp1:1.0
docker pull ghcr.io/ismailmifdal/devescops_tp1:1
```

Test rapide de l'image publiée :

```bash
docker run --rm -p 127.0.0.1:5000:5000 ghcr.io/ismailmifdal/devescops_tp1:1.0.0
curl http://127.0.0.1:5000/health
```

## 2. Comparatif Avant / Après

| Critère | Avant (`python:3.10-slim`) | Après (Chainguard Python) |
|---|---|---|
| Poids de l'image | 148 Mo | 84,7 Mo |
| Utilisateur d'exécution | `root` | `65532` (nonroot) |
| Shell présent | Oui (`/bin/sh`, `bash`) | Non |
| Gestionnaire de paquets / pip | Oui (`apt`, `pip`) | Non |
| CVE Trivy (toutes sévérités) | 185 (47 HIGH, 73 MEDIUM, 63 LOW, 2 UNKNOWN) | 0 |
| CVE Trivy HIGH/CRITICAL corrigibles | 3 | 0 |
| CVE Python (`requirements.txt`) | 19 entrées / 3 paquets | 0 |
| Efficience Dive | 97,35 % (5,7 Mo gaspillés) | 99,72 % (237 ko gaspillés) |
| Base PostgreSQL | `postgres:14-alpine` (tag mouvant) | `cgr.dev/chainguard/postgres` épinglée par digest |

## 3. Images de base retenues

**API** : `cgr.dev/chainguard/python`, en deux variantes de la même famille :

- `latest-dev` pour l'étage `builder` : contient `pip` et un shell, nécessaires pour créer le venv. Cet étage n'est jamais livré.
- `latest` pour l'étage `runtime` : uniquement l'interpréteur Python et ses bibliothèques, sans shell, sans gestionnaire de paquets, sans compilateur, utilisateur non-root par défaut.

Chainguard a été préféré à Distroless car ses images sont reconstruites en continu à partir de Wolfi (correctifs CVE rapides), signées, fournies avec un SBOM, et la paire `-dev`/runtime garantit la même version de Python entre construction et exécution.

**Base de données** : `cgr.dev/chainguard/postgres`, image minimale durcie compatible avec les variables `POSTGRES_*` de l'image officielle.

**Immuabilité et reproductibilité** : l'offre gratuite Chainguard ne publie que le tag `latest`. Toutes les images sont donc épinglées par **digest SHA256** (`image:latest@sha256:...`) : le digest identifie un contenu unique et immuable, le tag n'est plus qu'une annotation. Les dépendances Python sont épinglées en `==` sur l'arbre complet. Les outils CI (Hadolint, Dive, Trivy) sont téléchargés en version fixe et vérifiés par SHA256.

## 4. Healthchecks sans shell

Dans une image sans shell, `CMD-SHELL` et `curl`/`wget` sont indisponibles. Les deux sondes utilisent la forme exec `["CMD", ...]`, exécutée directement par le runtime de conteneurs.

- **API** : `["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"]`. On réutilise l'interpréteur déjà présent et sa bibliothèque standard. `urlopen` lève une exception (code retour 1) sur erreur réseau ou statut HTTP d'erreur.
- **PostgreSQL** : `["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "<user>", "-d", "<db>"]`, utilitaire client fourni dans l'image. `-h 127.0.0.1` force une connexion TCP : pendant l'initialisation, le serveur temporaire n'écoute que sur le socket local, la sonde ne passe donc au vert qu'une fois le vrai serveur prêt.
- **Synchronisation** : `depends_on: condition: service_healthy` empêche l'API de démarrer avant que PostgreSQL soit sain ; en CI, `docker compose up --wait --wait-timeout 120` attend l'état sain des deux services avec un délai maîtrisé.

Autres durcissements Compose : réseau `backend` en `internal: true` (base injoignable depuis l'hôte et Internet, port 5432 non publié), API publiée uniquement sur `127.0.0.1`, système de fichiers de l'API en lecture seule, `cap_drop: ALL`, `no-new-privileges`, secrets lus depuis un `.env` non versionné.

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

Pipeline : `flake8` + `hadolint` → `build` (BuildKit + Dive ≥ 80 %) → `security` (Trivy) + `integration` (Compose, /health, /dbtest, pytest) → `release` (GHCR).

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

### Dive (efficience ≥ 80 %)
```
$ CI=true dive --ci --lowestEfficiency=0.8 api:ci
  efficiency: 99.7206 %
  wastedBytes: 237208 bytes (237 kB)
  userWastedPercent: 0.4940 %
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

Toutes sévérités confondues (`trivy image`, sans filtre) : 185 CVE sur l'image d'origine, 0 sur l'image durcie.

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

### Tests d'intégration
```
$ docker compose --profile test run --rm tests
platform linux -- Python 3.14.8, pytest-9.1.1, pluggy-1.6.0 -- /app/venv/bin/python
collected 3 items

test_app.py::test_health PASSED                                          [ 33%]
test_app.py::test_hello PASSED                                           [ 66%]
test_app.py::test_dbtest PASSED                                          [100%]

============================== 3 passed in 0.30s ===============================
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

## Lancer le projet en local

```bash
cp .env.example .env        # puis changer le mot de passe
docker compose up -d --build --wait
curl http://127.0.0.1:5000/health
curl http://127.0.0.1:5000/dbtest
docker compose --profile test run --rm tests
docker compose --profile test down -v
```
