# DevSecOps TP1 : Hardening Flask + PostgreSQL

> Binôme : **NOM 1** / **NOM 2**

## 1. Packages GHCR publiés

| Package | URL |
|---|---|
| API Flask durcie | https://github.com/OWNER/REPO/pkgs/container/REPO |

```bash
docker pull ghcr.io/OWNER/REPO:1.0.0
docker pull ghcr.io/OWNER/REPO:1.0
docker pull ghcr.io/OWNER/REPO:1
```

Test rapide de l'image publiée :

```bash
docker run --rm -p 127.0.0.1:5000:5000 ghcr.io/OWNER/REPO:1.0.0
curl http://127.0.0.1:5000/health
```

## 2. Comparatif Avant / Après

| Critère | Avant (`python:3.10-slim`) | Après (Chainguard Python) |
|---|---|---|
| Poids de l'image | À COMPLÉTER Mo | À COMPLÉTER Mo |
| Utilisateur d'exécution | `root` | `65532` (nonroot) |
| Shell présent | Oui (`/bin/sh`, `bash`) | Non |
| Gestionnaire de paquets / pip | Oui (`apt`, `pip`) | Non |
| CVE Trivy (toutes sévérités) | À COMPLÉTER | À COMPLÉTER |
| CVE Trivy HIGH/CRITICAL corrigibles | À COMPLÉTER | 0 |
| CVE Python (`requirements.txt`) | 19 entrées / 3 paquets | 0 |
| Efficience Dive | À COMPLÉTER % | À COMPLÉTER % |
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

Run GitHub Actions : À COMPLÉTER (lien)

### Flake8
```
À COLLER
```

### Hadolint
```
À COLLER
```

### Dive (efficience ≥ 80 %)
```
À COLLER
```

### Trivy
```
À COLLER
```

### Compose : services sains
```
À COLLER (docker compose ps)
```

### Tests d'intégration
```
À COLLER (pytest)
```

### Publication GHCR
```
À COLLER (docker pull ...)
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
