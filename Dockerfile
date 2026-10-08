# syntax=docker/dockerfile:1

# =====================================================================
# Étage 1 : builder (image -dev : pip + shell, jamais livrée)
# =====================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:...TON DIGEST... AS builder      ← NE PAS TOUCHER
WORKDIR /app
# venv SANS pip : aucun gestionnaire de paquets ne sera livré dans le runtime
RUN python -m venv --without-pip /app/venv
# Manifeste isolé avant le code : le cache pip survit aux modifs de app.py
COPY requirements.txt .
# Le pip système de l'image -dev installe DANS le venv (--python)
RUN pip install --no-cache-dir --python /app/venv/bin/python -r requirements.txt
ENV PATH="/app/venv/bin:${PATH}"

# =====================================================================
# Étage 2 : test (outillage pytest, utilisé uniquement en CI)
# =====================================================================
FROM builder AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir --python /app/venv/bin/python -r requirements-dev.txt
COPY app.py .
ENTRYPOINT ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

# =====================================================================
# Étage 3 : runtime (sans shell, sans pip, sans compilateur, non-root)
# =====================================================================
FROM cgr.dev/chainguard/python:latest@sha256:...TON DIGEST... AS runtime      ← NE PAS TOUCHER
WORKDIR /app
ENV PATH="/app/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=builder /app/venv /app/venv
COPY app.py .
USER 65532:65532
EXPOSE 5000
ENTRYPOINT ["python", "app.py"]