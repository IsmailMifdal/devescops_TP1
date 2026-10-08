# syntax=docker/dockerfile:1

# =====================================================================
# Étage 1 : builder (image -dev : pip + shell, jamais livrée)
# =====================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder
WORKDIR /app
RUN python -m venv /app/venv
ENV PATH="/app/venv/bin:${PATH}"
# Manifeste isolé avant le code : le cache pip survit aux modifs de app.py
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# =====================================================================
# Étage 2 : test (outillage pytest, utilisé uniquement en CI)
# =====================================================================
FROM builder AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY app.py .
ENTRYPOINT ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

# =====================================================================
# Étage 3 : runtime (sans shell, sans pip, sans compilateur, non-root)
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
