# syntax=docker/dockerfile:1

# =====================================================================
# Etage 1 : builder (image -dev : pip + shell, jamais livree)
# =====================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder
WORKDIR /app
# venv SANS pip : aucun gestionnaire de paquets ne sera livre dans le runtime
RUN python -m venv --without-pip /app/venv
# Manifeste isole avant le code : le cache pip survit aux modifs de app.py
COPY requirements.txt .
# Le pip systeme de l'image -dev installe DANS le venv (--python)
RUN pip --python /app/venv/bin/python install --no-cache-dir -r requirements.txt
ENV PATH="/app/venv/bin:${PATH}"

# =====================================================================
# Etage 2 : test (outillage pytest, utilise uniquement en CI)
# =====================================================================
FROM builder AS test
COPY requirements-dev.txt .
RUN pip --python /app/venv/bin/python install --no-cache-dir -r requirements-dev.txt
COPY app.py .
ENTRYPOINT ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

# =====================================================================
# Etage 3 : runtime (sans shell, sans pip, sans compilateur, non-root)
# =====================================================================
FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46 AS runtime
WORKDIR /app
ENV PATH="/app/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=builder /app/venv /app/venv
COPY app.py .
USER 65532:65532
EXPOSE 5000
ENTRYPOINT ["python", "app.py"]