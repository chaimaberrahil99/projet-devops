#!/usr/bin/env bash
#
# Installe k3s DIRECTEMENT sur cette machine (pas dans des conteneurs).
#
# Architecture obtenue :
#   la machine WSL  =  la VM
#   cette machine   =  l'unique noeud du cluster
#   vos pods        =  des conteneurs geres par containerd, sur cette machine
#
# Aucun emboitement : pas de conteneur-noeud, pas de conteneur dans un
# conteneur. k3s s'installe comme un service systeme ordinaire.
#
# A lancer UNE SEULE FOIS :
#   ./infra/k8s/install-k3s.sh
#
# Pour desinstaller :
#   /usr/local/bin/k3s-uninstall.sh

set -euo pipefail

etape() { echo; echo "=== $* ==="; }

if command -v k3s >/dev/null 2>&1; then
    etape "k3s est deja installe"
    sudo systemctl status k3s --no-pager | head -5 || true
else
    etape "Verification de systemd"
    if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
        cat >&2 <<'MSG'
Erreur : systemd n'est pas actif dans cette distribution WSL, or k3s en a besoin.

Pour l'activer :
  1. sudo nano /etc/wsl.conf   et ajouter :
         [boot]
         systemd=true
  2. Depuis PowerShell sous Windows :  wsl --shutdown
  3. Rouvrir le terminal Ubuntu, puis relancer ce script.
MSG
        exit 1
    fi

    etape "Installation de k3s"
    # --write-kubeconfig-mode 644 : permet a kubectl de fonctionner sans sudo.
    # --disable=traefik          : inutile ici (Nginx fait deja le routage)
    #                              et economise de la memoire.
    # servicelb reste actif : c'est lui qui expose les services LoadBalancer
    # sur le port 80 de la machine.
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable=traefik" sh -
fi

etape "Configuration de kubectl"
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

etape "Attente du demarrage du cluster"
for _ in $(seq 1 30); do
    if kubectl get nodes >/dev/null 2>&1; then break; fi
    sleep 2
done

etape "Etat du cluster"
kubectl get nodes
echo
echo "Le noeud doit apparaitre en Ready. Si ce n'est pas le cas apres une"
echo "minute :  sudo journalctl -u k3s -n 50 --no-pager"
echo
echo "Etape suivante :  ./infra/k8s/bootstrap.sh"
