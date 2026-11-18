#!/usr/bin/env bash
# scripts/wipeitclean.sh — Suppression de toutes les ressources Azure Quiz App
#
# ⚠️  ACTION IRRÉVERSIBLE — toutes les ressources du groupe seront supprimées.
# Conservez vos preuves (captures, logs) avant d'exécuter ce script.
#
# Usage :
#   chmod +x scripts/wipeitclean.sh
#   ./scripts/wipeitclean.sh

set -euo pipefail

RESOURCE_GROUP="quiz-app-rg"
ACR_NAME="quizappacr"

echo "=== Suppression des ressources Azure Quiz App ==="
echo ""
echo "  Groupe de ressources : $RESOURCE_GROUP"
echo "  ACR                  : $ACR_NAME"
echo ""
read -r -p "Confirmez la suppression (oui/non) : " CONFIRM

if [[ "$CONFIRM" != "oui" ]]; then
  echo "Suppression annulée."
  exit 0
fi

echo ""
echo "[1/2] Suppression du groupe de ressources (Container Apps, ACR, Log Analytics)..."
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait
echo "  Suppression lancée en arrière-plan."

echo ""
echo "[2/2] Nettoyage des images Docker locales taguées ACR..."
docker images --format "{{.Repository}}:{{.Tag}}" \
  | grep "${ACR_NAME}.azurecr.io" \
  | xargs -r docker rmi 2>/dev/null || true
echo "  OK"

echo ""
echo "=== Destroy lancé. Vérifiez la progression avec : ==="
echo "  az group show --name $RESOURCE_GROUP --query properties.provisioningState"
