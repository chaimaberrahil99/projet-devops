#!/usr/bin/env bash
#
# DEPLOIEMENT CONTINU "TIRE" (pull-based).
#
# Pourquoi ce script existe : le pipeline GitHub Actions s'execute sur les
# serveurs de GitHub. Pour qu'il deploie lui-meme sur une machine, il faudrait
# pouvoir s'y connecter -- impossible si la machine n'a pas d'adresse publique
# (PC derriere une box, reseau d'ecole, VM locale).
#
# On inverse donc le sens : ce n'est plus GitHub qui pousse vers la machine,
# c'est la machine qui va chercher. Elle interroge le registry a intervalle
# regulier et redeploie des qu'une nouvelle image est publiee.
#
# C'est le principe de GitOps, celui de FluxCD et ArgoCD cites dans le sujet,
# reduit a sa plus simple expression.
#
# Usage :
#   ./infra/compose/watch-deploy.sh              # verifie toutes les 120 s
#   INTERVALLE=30 ./infra/compose/watch-deploy.sh
#
# Pour le laisser tourner en permanence, voir infra/systemd/ (service systemd).

set -uo pipefail

cd "$(dirname "$0")/../.."

COMPOSE=(docker compose -f infra/compose/docker-compose.prod.yml --env-file .env)
INTERVALLE="${INTERVALLE:-120}"

if [ ! -f .env ]; then
    echo "Erreur : fichier .env introuvable a la racine du depot." >&2
    exit 1
fi

# shellcheck disable=SC1091
source .env
TAG="${TAG:-latest}"
IMAGE_BACKEND="${IMAGE_PREFIX}/backend:${TAG}"
IMAGE_FRONTEND="${IMAGE_PREFIX}/frontend:${TAG}"

if [ "${IMAGE_PREFIX}" = "ghcr.io/OWNER/REPO" ]; then
    echo "Erreur : IMAGE_PREFIX n'a pas ete modifie dans .env." >&2
    exit 1
fi

journal() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Identifiant local de l'image : change si et seulement si une nouvelle
# version a ete telechargee depuis le registry.
empreinte() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || echo absente
}

etat_actuel() {
    echo "$(empreinte "$IMAGE_BACKEND")|$(empreinte "$IMAGE_FRONTEND")"
}

redeployer() {
    journal "Nouvelle version detectee, redeploiement en cours"
    # --wait : ne rend la main qu'une fois les conteneurs declares sains.
    if "${COMPOSE[@]}" up -d --wait; then
        # Migrations idempotentes, jouees apres la mise a jour des conteneurs.
        "${COMPOSE[@]}" --profile migrate run --rm migrate >/dev/null 2>&1 \
            || journal "Migrations ignorees (base deja a jour)"
        journal "Redeploiement termine avec succes"
    else
        journal "ECHEC du redeploiement -- l'ancienne version reste en service"
    fi
}

journal "Surveillance demarree : $IMAGE_BACKEND"
journal "Verification du registry toutes les ${INTERVALLE} s"

# Premiere boucle : on s'assure que la stack tourne, meme sans nouvelle image.
"${COMPOSE[@]}" up -d --wait >/dev/null 2>&1 \
    && journal "Stack demarree" \
    || journal "Attention : la stack n'a pas demarre correctement"

while true; do
    avant="$(etat_actuel)"
    "${COMPOSE[@]}" pull --quiet >/dev/null 2>&1 \
        || journal "Registry injoignable, nouvel essai au prochain cycle"
    apres="$(etat_actuel)"

    if [ "$avant" != "$apres" ]; then
        redeployer
    fi

    sleep "$INTERVALLE"
done
