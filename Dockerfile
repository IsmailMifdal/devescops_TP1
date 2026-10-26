# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Frontend BuildKit explicite (syntaxe étendue : RUN --mount), épinglé par digest

# =====================================================================
# Etage 1 : builder (image -dev : pip + shell, jamais livree)
# =====================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:dde1a2549dd62864f0263dae8e877680837b4e738a7ecc85c671c55c069848ac AS builder
WORKDIR /app
# venv SANS pip : aucun gestionnaire de paquets ne sera livre dans le runtime
RUN python -m venv --without-pip /app/venv
# Manifeste isole avant le code : la couche d'installation survit aux modifs de app.py
COPY requirements.txt .
# - Cache pip : montage persistant gere par BuildKit, HORS couche. Seul le delta
#   du manifeste est telecharge ; rien n'est ecrit dans l'image (UID 65532 = nonroot).
# - Jeton du depot interne : secret monte en tmpfs dans /run/secrets/pip_token
#   pour ce seul RUN, verifie, puis demonte. Ni ARG, ni ENV.
RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    --mount=type=secret,id=pip_token,required=true,uid=65532,gid=65532,mode=0400 \
    if ! grep -q " /run/secrets/pip_token tmpfs " /proc/mounts; then \
      echo "ERREUR : le secret n'est pas monte en memoire (tmpfs)" >&2; exit 1; \
    fi \
    && if ! grep -Eq "^[A-Za-z0-9_-]{32,}$" /run/secrets/pip_token; then \
      echo "ERREUR : jeton du depot interne absent ou invalide" >&2; exit 1; \
    fi \
    && echo "Jeton du depot interne verifie (tmpfs, contenu non affiche)" \
    && pip --python /app/venv/bin/python install --disable-pip-version-check \
       --progress-bar off -r requirements.txt
ENV PATH="/app/venv/bin:${PATH}"

# =====================================================================
# Etage 2 : test (outillage pytest, utilise uniquement en CI)
# =====================================================================
FROM builder AS test
COPY requirements-dev.txt .
RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    pip --python /app/venv/bin/python install --disable-pip-version-check \
    --progress-bar off -r requirements-dev.txt
COPY app.py .
ENTRYPOINT ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

# =====================================================================
# Etage 3 : runtime (sans shell, sans pip, sans compilateur, non-root)
# =====================================================================
FROM cgr.dev/chainguard/python:latest@sha256:49fd266eb8a1331194c318b742087c7a2939cc5794fa64f17feb9e17e12703e2 AS runtime
WORKDIR /app
ENV PATH="/app/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=builder /app/venv /app/venv
COPY app.py .
USER 65532:65532
EXPOSE 5000
ENTRYPOINT ["python", "app.py"]
