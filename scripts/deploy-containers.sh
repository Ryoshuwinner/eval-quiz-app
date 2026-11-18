#!/usr/bin/env bash
# scripts/deploy-containers.sh — Déploiement Quiz App sur Azure Container Apps
#
# Prérequis :
#   - Azure CLI installé et connecté (az login)
#   - Docker installé et démon en cours d'exécution
#   - Variables d'environnement définies dans .env (voir .env.example)
#
# Usage :
#   chmod +x scripts/deploy-containers.sh
#   ./scripts/deploy-containers.sh [--tag v1.2]
#
# Par défaut le tag est basé sur le commit Git courant.

set -euo pipefail

# ─── Chargement de .env ───────────────────────────────────────────────────────
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# ─── Configuration ────────────────────────────────────────────────────────────
RESOURCE_GROUP="quiz-app-rg"
LOCATION="norwayeast"
ACR_NAME="quizappacr"
ACR_SERVER="${ACR_NAME}.azurecr.io"
ENVIRONMENT="quiz-app-env"
BACKEND_APP="quiz-backend"
FRONTEND_APP="quiz-frontend"

# Tag : commit Git court ou valeur passée en argument
GIT_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
TAG="${1:-${GIT_TAG}}"
if [[ "${1:-}" == "--tag" && -n "${2:-}" ]]; then TAG="$2"; fi

echo "=== Déploiement Quiz App — tag: ${TAG} ==="

# ─── 1. Vérification connexion Azure ──────────────────────────────────────────
echo "[1/6] Vérification connexion Azure..."
az account show --query "{abonnement:name, user:user.name}" -o table

# ─── 2. Groupe de ressources ───────────────────────────────────────────────────
echo "[2/6] Groupe de ressources..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
echo "  OK : $RESOURCE_GROUP"

# ─── 3. ACR ───────────────────────────────────────────────────────────────────
echo "[3/6] Azure Container Registry..."
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --location "$LOCATION" \
  --admin-enabled true \
  --output none 2>/dev/null || echo "  ACR déjà existant, on continue."
echo "  OK : ${ACR_SERVER}"

# ─── 4. Build et push des images ──────────────────────────────────────────────
echo "[4/6] Build et push des images..."
az acr login --name "$ACR_NAME"

docker build \
  -f Dockerfile.cloud \
  -t "${ACR_SERVER}/${FRONTEND_APP}:${TAG}" \
  -t "${ACR_SERVER}/${FRONTEND_APP}:latest" \
  .

docker build \
  -f backend/Dockerfile \
  -t "${ACR_SERVER}/${BACKEND_APP}:${TAG}" \
  -t "${ACR_SERVER}/${BACKEND_APP}:latest" \
  ./backend

docker push "${ACR_SERVER}/${FRONTEND_APP}:${TAG}"
docker push "${ACR_SERVER}/${FRONTEND_APP}:latest"
docker push "${ACR_SERVER}/${BACKEND_APP}:${TAG}"
docker push "${ACR_SERVER}/${BACKEND_APP}:latest"
echo "  OK : images poussées avec le tag ${TAG}"

# ─── 5. Environnement Container Apps ──────────────────────────────────────────
echo "[5/6] Environnement Container Apps..."
az containerapp env create \
  --name "$ENVIRONMENT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none 2>/dev/null || echo "  Environnement déjà existant, on continue."
echo "  OK : $ENVIRONMENT"

ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

# ─── 6. Déploiement des Container Apps ────────────────────────────────────────
echo "[6/6] Déploiement des Container Apps..."

# Backend
if az containerapp show --name "$BACKEND_APP" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az containerapp update \
    --name "$BACKEND_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --image "${ACR_SERVER}/${BACKEND_APP}:${TAG}" \
    --set-env-vars \
      "RESEND_API_KEY=${RESEND_API_KEY:-re_placeholder}" \
      "ADMIN_USERNAME=${ADMIN_USERNAME:-admin}" \
      "ADMIN_PASSWORD=${ADMIN_PASSWORD:-changeme}" \
      "JWT_SECRET=${JWT_SECRET:-change-this}" \
      "FROM_EMAIL=${FROM_EMAIL:-noreply@example.com}" \
      "DATABASE_URL=${DATABASE_URL:-}" \
    --output none
else
  az containerapp create \
    --name "$BACKEND_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --environment "$ENVIRONMENT" \
    --image "${ACR_SERVER}/${BACKEND_APP}:${TAG}" \
    --registry-server "$ACR_SERVER" \
    --registry-username "$ACR_NAME" \
    --registry-password "$ACR_PASSWORD" \
    --target-port 3007 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 2 \
    --cpu 0.25 \
    --memory 0.5Gi \
    --env-vars \
      "RESEND_API_KEY=${RESEND_API_KEY:-re_placeholder}" \
      "ADMIN_USERNAME=${ADMIN_USERNAME:-admin}" \
      "ADMIN_PASSWORD=${ADMIN_PASSWORD:-changeme}" \
      "JWT_SECRET=${JWT_SECRET:-change-this}" \
      "FROM_EMAIL=${FROM_EMAIL:-noreply@example.com}" \
      "DATABASE_URL=${DATABASE_URL:-}" \
    --output none
fi
echo "  OK : $BACKEND_APP"

# Attendre que le backend soit joignable avant de démarrer le frontend
# (évite le crash Nginx "host not found in upstream" au démarrage)
echo "  Attente du backend..."
BACKEND_URL=$(az containerapp show \
  --name "$BACKEND_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

# Mettre à jour BACKEND_FQDN dans .env avec le FQDN réel du backend
if [[ -f .env ]]; then
  if grep -q "^BACKEND_FQDN=" .env; then
    sed -i "s|^BACKEND_FQDN=.*|BACKEND_FQDN=${BACKEND_URL}|" .env
  else
    echo "BACKEND_FQDN=${BACKEND_URL}" >> .env
  fi
fi

for i in $(seq 1 24); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${BACKEND_URL}/health" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    echo "  Backend prêt (HTTP 200) après $((i * 5))s"
    break
  fi
  echo "  Tentative $i/24 — HTTP $STATUS, nouvelle tentative dans 5s..."
  sleep 5
done

# Frontend
if az containerapp show --name "$FRONTEND_APP" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az containerapp update \
    --name "$FRONTEND_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --image "${ACR_SERVER}/${FRONTEND_APP}:${TAG}" \
    --set-env-vars "BACKEND_FQDN=${BACKEND_URL}" \
    --output none
else
  az containerapp create \
    --name "$FRONTEND_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --environment "$ENVIRONMENT" \
    --image "${ACR_SERVER}/${FRONTEND_APP}:${TAG}" \
    --registry-server "$ACR_SERVER" \
    --registry-username "$ACR_NAME" \
    --registry-password "$ACR_PASSWORD" \
    --target-port 80 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 2 \
    --cpu 0.25 \
    --memory 0.5Gi \
    --env-vars "BACKEND_FQDN=${BACKEND_URL}" \
    --output none
fi
echo "  OK : $FRONTEND_APP"

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Déploiement terminé ==="
FRONTEND_URL=$(az containerapp show \
  --name "$FRONTEND_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
BACKEND_URL=$(az containerapp show \
  --name "$BACKEND_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "  Frontend : https://${FRONTEND_URL}"
echo "  Backend  : https://${BACKEND_URL}/health"
echo "  Tag      : ${TAG}"
