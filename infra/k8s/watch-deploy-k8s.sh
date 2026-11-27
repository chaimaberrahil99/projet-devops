#!/usr/bin/env bash
#
# DEPLOIEMENT CONTINU vers le cluster Kubernetes.
#
# Equivalent de infra/compose/watch-deploy.sh, mais pour Kubernetes.
# Difference essentielle : au lieu de relancer des conteneurs, il demande a
# Kubernetes de mettre a jour les Deployments -- ce qui declenche une mise a
# jour PROGRESSIVE, sans interruption de service.
#
# Comment il detecte une nouvelle version : il interroge le registry et lit
# le "digest" de l'image, son empreinte unique. Si elle a change, une nouvelle
# image a ete publiee.
#
# Pourquoi epingler le digest plutot que le tag `latest` : un tag peut pointer
# sur n'importe quoi et changer dans le dos. Un digest designe UN contenu
# precis, pour toujours. On deploie donc exactement ce qu'on a observe, et
# `kubectl set image` declenche la mise a jour parce que la valeur change
# reellement.
#
# Usage :
#   ./infra/k8s/watch-deploy-k8s.sh
#   INTERVALLE=30 ./infra/k8s/watch-deploy-k8s.sh

set -uo pipefail

cd "$(dirname "$0")/../.."

NAMESPACE="${NAMESPACE:-tasks}"
INTERVALLE="${INTERVALLE:-60}"

if [ ! -f .env ]; then
    echo "Erreur : fichier .env introuvable a la racine du depot." >&2
    exit 1
fi
# shellcheck disable=SC1091
source .env
TAG="${TAG:-latest}"
IMAGE_BACKEND="${IMAGE_PREFIX}/backend:${TAG}"
IMAGE_FRONTEND="${IMAGE_PREFIX}/frontend:${TAG}"

journal() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for outil in kubectl docker; do
    if ! commande=$(command -v "$outil"); then
        journal "Erreur : '$outil' est introuvable."
        exit 1
    fi
done

if ! erreur=$(kubectl cluster-info 2>&1); then
    journal "Le cluster Kubernetes ne repond pas. Message exact :"
    echo "$erreur" >&2
    exit 1
fi

# Empreinte de l'image telle qu'elle existe DANS LE REGISTRY, sans la
# telecharger. buildx est livre avec Docker Desktop.
digest_distant() {
    docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null \
        || echo indisponible
}

deployer() {
    local nom="$1" image_sans_tag="$2" digest="$3"
    kubectl set image "deployment/$nom" "$nom=${image_sans_tag}@${digest}" -n "$NAMESPACE"
}

journal "Surveillance du registry demarree (toutes les ${INTERVALLE} s)"
journal "Cluster : $(kubectl config current-context) | namespace : $NAMESPACE"

precedent_backend=""
precedent_frontend=""

while true; do
    d_backend="$(digest_distant "$IMAGE_BACKEND")"
    d_frontend="$(digest_distant "$IMAGE_FRONTEND")"

    if [ "$d_backend" = indisponible ] || [ "$d_frontend" = indisponible ]; then
        journal "Registry injoignable, nouvel essai au prochain cycle"
        sleep "$INTERVALLE"
        continue
    fi

    change=0
    if [ "$d_backend" != "$precedent_backend" ]; then
        [ -n "$precedent_backend" ] && journal "Nouvelle image backend : ${d_backend:0:19}..."
        deployer backend "${IMAGE_PREFIX}/backend" "$d_backend" >/dev/null
        precedent_backend="$d_backend"
        change=1
    fi
    if [ "$d_frontend" != "$precedent_frontend" ]; then
        [ -n "$precedent_frontend" ] && journal "Nouvelle image frontend : ${d_frontend:0:19}..."
        deployer frontend "${IMAGE_PREFIX}/frontend" "$d_frontend" >/dev/null
        precedent_frontend="$d_frontend"
        change=1
    fi

    if [ "$change" = 1 ]; then
        journal "Mise a jour progressive en cours (sans interruption)"
        # `rollout status` ne rend la main que lorsque TOUS les pods neufs sont
        # prets. Si ca echoue, on restaure la version precedente.
        if kubectl rollout status deployment/backend  -n "$NAMESPACE" --timeout=180s >/dev/null \
        && kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s >/dev/null; then
            journal "Mise a jour terminee avec succes"
        else
            journal "ECHEC : retour a la version precedente"
            kubectl rollout undo deployment/backend  -n "$NAMESPACE" || true
            kubectl rollout undo deployment/frontend -n "$NAMESPACE" || true
        fi
    fi

    sleep "$INTERVALLE"
done
