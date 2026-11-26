#!/usr/bin/env bash
# Deploiement en production sur la VM.
#
# Usage, depuis la racine du depot clone sur la VM :
#   ./infra/compose/deploy.sh            # deploie le tag `latest`
#   ./infra/compose/deploy.sh sha-a1b2c3d   # deploie un commit precis
#
# Ce script est l'etape "manuelle" du deploiement continu, celle que le README
# documente. Pour l'automatiser plus tard, il suffira de l'appeler en SSH
# depuis le pipeline.

set -euo pipefail

cd "$(dirname "$0")/../.."
COMPOSE="docker compose -f infra/compose/docker-compose.prod.yml --env-file .env"

export TAG="${1:-latest}"
echo "==> Deploiement du tag : $TAG"

echo "==> Recuperation des images depuis le registry"
$COMPOSE pull

echo "==> Demarrage / mise a jour des services"
# --wait : la commande ne rend la main que lorsque les healthchecks passent.
# C'est l'equivalent Docker Compose de `kubectl rollout status`.
$COMPOSE up -d --wait

echo "==> Application du schema (idempotent)"
$COMPOSE --profile migrate run --rm migrate || \
  echo "(migration ignoree : la base etait deja a jour)"

echo "==> Etat des services"
$COMPOSE ps

echo
echo "==> Deploiement termine. Application : http://$(hostname -I 2>/dev/null | awk '{print $1}')/"
