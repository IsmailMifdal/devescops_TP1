# syntax=docker/dockerfile:1

# =====================================================================
# Etage 1 : builder (image -dev : pip + shell, jamais livree)
# =====================================================================
FROM cgr.dev/chainguard/python:latest-dev@sha256:dde1a2549dd62864f0263dae8e877680837b4e738a7ecc85c671c55c069848ac AS builder
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