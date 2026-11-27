#!/usr/bin/env bash
#
# Deploie l'application sur le cluster k3s, de zero.
#
# Prerequis : k3s installe sur cette machine (./infra/k8s/install-k3s.sh).
#
# A lancer depuis la racine du depot :
#   ./infra/k8s/bootstrap.sh
#
# Le script est idempotent : on peut le relancer autant de fois que necessaire.

set -euo pipefail

cd "$(dirname "$0")/../.."
NAMESPACE=tasks

etape() { echo; echo "=== $* ==="; }

command -v kubectl >/dev/null || { echo "Erreur : kubectl introuvable." >&2; exit 1; }

if ! erreur=$(kubectl get nodes 2>&1); then
    echo "Le cluster ne repond pas. Message exact :" >&2
    echo "$erreur" >&2
    echo >&2
    echo "Si k3s n'est pas encore installe :  ./infra/k8s/install-k3s.sh" >&2
    exit 1
fi

etape "Noeud du cluster"
kubectl get nodes

# --- metrics-server ---------------------------------------------------------
# k3s l'embarque d'origine : rien a installer. Sans lui, l'auto-scaling
# resterait bloque sur <unknown>.
#
# Attention au timing : k3s cree ce deploiement quelques dizaines de secondes
# APRES que le noeud passe en Ready. Lancer `rollout status` trop tot echoue
# avec "not found" -- on attend donc d'abord qu'il existe.
etape "Attente de metrics-server (fourni par k3s)"
for _ in $(seq 1 60); do
    kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1 && break
    sleep 2
done
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "metrics-server n'est toujours pas la apres 2 minutes." >&2
    echo "Verifier :  kubectl get pods -n kube-system" >&2
    exit 1
fi
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s

# --- L'application ----------------------------------------------------------
etape "Deploiement de l'application"
kubectl apply -k infra/k8s/

etape "Attente de la base de donnees"
kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=180s

# --- Le schema --------------------------------------------------------------
# Genere depuis app/db/init.sql : une seule source de verite pour le schema,
# partagee avec l'environnement Docker Compose. Le script est idempotent.
etape "Application du schema (Job dedie)"
kubectl create configmap db-init -n "$NAMESPACE" \
    --from-file=init.sql=app/db/init.sql \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job db-migrate -n "$NAMESPACE" --ignore-not-found
kubectl apply -f infra/k8s/job-migrate.yaml
kubectl wait --for=condition=complete job/db-migrate -n "$NAMESPACE" --timeout=180s

etape "Attente des pods applicatifs"
kubectl rollout status deployment/backend  -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s

# --- Supervision ------------------------------------------------------------
etape "Deploiement de Prometheus et Grafana"
kubectl apply -f infra/k8s/monitoring/prometheus.yaml
kubectl apply -f infra/k8s/monitoring/grafana.yaml
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s
kubectl rollout status deployment/grafana    -n monitoring --timeout=180s

# --- Verification -----------------------------------------------------------
etape "Pods deployes"
kubectl get pods -n "$NAMESPACE" -o wide

etape "Auto-scaling"
echo "(la colonne TARGETS reste a <unknown> une a deux minutes, le temps que"
echo " metrics-server collecte ses premieres mesures)"
kubectl get hpa -n "$NAMESPACE"

echo
echo "=============================================================="
echo " Application :  http://localhost"
echo " Grafana     :  http://localhost:3000   (consultation libre)"
echo
echo " Deploiement continu :  ./infra/k8s/watch-deploy-k8s.sh"
echo "=============================================================="
