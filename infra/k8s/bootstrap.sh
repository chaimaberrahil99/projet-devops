#!/usr/bin/env bash
#
# Monte le cluster Kubernetes local et y deploie l'application, de zero.
#
# A lancer depuis la racine du depot :
#   ./infra/k8s/bootstrap.sh
#
# Pour tout detruire et recommencer :
#   k3d cluster delete projet-devops

set -euo pipefail

cd "$(dirname "$0")/../.."
NAMESPACE=tasks

etape() { echo; echo "=== $* ==="; }

for outil in k3d kubectl docker; do
    command -v "$outil" >/dev/null || { echo "Erreur : '$outil' introuvable." >&2; exit 1; }
done

# --- 1. Le cluster ----------------------------------------------------------
if k3d cluster list 2>/dev/null | grep -q '^projet-devops '; then
    etape "Cluster deja present, on le reutilise"
    k3d cluster start projet-devops >/dev/null 2>&1 || true
else
    etape "Creation du cluster k3s multi-noeuds (quelques minutes au premier lancement)"
    k3d cluster create --config infra/k8s/k3d-cluster.yaml
fi

kubectl config use-context k3d-projet-devops >/dev/null
etape "Noeuds du cluster"
kubectl get nodes

# --- 2. metrics-server ------------------------------------------------------
# k3s l'embarque d'origine -- rien a installer. Sans lui, l'auto-scaling
# resterait bloque sur <unknown>. On attend simplement qu'il soit pret.
etape "Attente de metrics-server (fourni par k3s)"
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s

# --- 3. L'application -------------------------------------------------------
etape "Deploiement de l'application"
kubectl apply -k infra/k8s/

etape "Attente de la base de donnees"
kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=180s

# --- 4. Le schema -----------------------------------------------------------
# Le ConfigMap est genere depuis app/db/init.sql : une seule source de verite
# pour le schema, partagee avec l'environnement Docker Compose.
etape "Application du schema (Job dedie, script idempotent)"
kubectl create configmap db-init -n "$NAMESPACE" \
    --from-file=init.sql=app/db/init.sql \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job db-migrate -n "$NAMESPACE" --ignore-not-found
kubectl apply -f infra/k8s/job-migrate.yaml
kubectl wait --for=condition=complete job/db-migrate -n "$NAMESPACE" --timeout=180s

etape "Attente des pods applicatifs"
kubectl rollout status deployment/backend  -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s

# --- 5. Supervision ---------------------------------------------------------
etape "Deploiement de Prometheus et Grafana"
kubectl apply -f infra/k8s/monitoring/prometheus.yaml
kubectl apply -f infra/k8s/monitoring/grafana.yaml
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s
kubectl rollout status deployment/grafana    -n monitoring --timeout=180s

# --- 6. Verification --------------------------------------------------------
etape "Repartition des pods sur les noeuds"
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
