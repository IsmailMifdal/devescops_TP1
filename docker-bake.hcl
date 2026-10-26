# =====================================================================
# Build déclaratif de l'API (docker buildx bake)
#
#   docker buildx bake                 -> image multi-arch (amd64 + arm64)
#   docker buildx bake api-local       -> image amd64 chargée localement
#   VERSION=1.2.0 docker buildx bake --push
#
# Chaque variable peut être surchargée par une variable d'environnement
# du même nom (ex. CACHE_BACKEND=gha en CI).
# =====================================================================

# Identifiant de registre et nom d'image (références OCI en minuscules)
variable "REGISTRY" {
  default = "ghcr.io"
}

variable "IMAGE_NAME" {
  default = "ismailmifdal/devescops_tp1"
}

# Étiquette de version par défaut (remplacée par les tags SemVer en release)
variable "VERSION" {
  default = "dev"
}

# Architectures processeur ciblées : x86_64 et ARM 64 bits
variable "PLATFORMS" {
  default = ["linux/amd64", "linux/arm64"]
}

# Fichier local du jeton du dépôt interne (non versionné, hors contexte)
variable "PIP_TOKEN_FILE" {
  default = "secrets/pip_token"
}

# Backend du cache externe : "local" (poste de travail) ou "gha" (runners
# GitHub Actions éphémères, sans droit d'écriture supplémentaire)
variable "CACHE_BACKEND" {
  default = "local"
}

variable "CACHE_SCOPE" {
  default = "api"
}

function "cache_from" {
  params = [backend, scope]
  result = backend == "gha" ? ["type=gha,scope=${scope}"] : ["type=local,src=.buildx-cache"]
}

# mode=max : exporte aussi les couches des étages intermédiaires (builder)
function "cache_to" {
  params = [backend, scope]
  result = backend == "gha" ? ["type=gha,scope=${scope},mode=max"] : ["type=local,dest=.buildx-cache,mode=max"]
}

group "default" {
  targets = ["api"]
}

# Tags et labels par défaut. En release, docker/metadata-action génère un
# fichier bake qui redéfinit cette cible avec les tags SemVer calculés.
target "docker-metadata-action" {
  tags = ["${REGISTRY}/${IMAGE_NAME}:${VERSION}"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  # Secret de build monté en tmpfs dans l'étage builder (RUN --mount=type=secret)
  secret     = ["id=pip_token,src=${PIP_TOKEN_FILE}"]
  cache-from = cache_from(CACHE_BACKEND, CACHE_SCOPE)
  cache-to   = cache_to(CACHE_BACKEND, CACHE_SCOPE)
  labels = {
    "org.opencontainers.image.title"       = "devsecops-tp1-api"
    "org.opencontainers.image.description" = "API Flask durcie (Chainguard Python, multi-arch)"
    "org.opencontainers.image.source"      = "https://github.com/IsmailMifdal/devescops_TP1"
    "org.opencontainers.image.licenses"    = "MIT"
  }
}

# Image de production multi-architecture : un index OCI unique amd64 + arm64
target "api" {
  inherits  = ["_common", "docker-metadata-action"]
  target    = "runtime"
  platforms = PLATFORMS
}

# Variante mono-architecture chargée dans le démon Docker local : un index
# multi-arch ne peut pas être chargé (--load) ; sert à Dive, Trivy et Compose.
# Elle IMPORTE le cache sans l'exporter : un export remplace l'index du scope
# et effacerait le cache multi-arch produit par la cible "api".
target "api-local" {
  inherits  = ["api"]
  platforms = ["linux/amd64"]
  tags      = ["api:ci"]
  output    = ["type=docker"]
  cache-to  = []
}
