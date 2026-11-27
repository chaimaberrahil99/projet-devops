# Déroulé de la démonstration

Les huit points demandés, dans l'ordre, avec les commandes exactes.

**Durée : 12 à 15 minutes.** À répéter en entier au moins une fois avant.

---

## Avant l'arrivée du prof

### Vérifier que tout tourne

```bash
kubectl get nodes                      # 3 nœuds Ready
kubectl get pods -n tasks              # tous Running
kubectl get pods -n monitoring         # prometheus et grafana Running
pgrep -af watch-deploy-k8s.sh          # une seule ligne
sudo systemctl is-active k3s           # active
```

Si la surveillance ne tourne pas :
```bash
cd ~/projet-devops && ./infra/k8s/watch-deploy-k8s.sh
```

### Préparer les fenêtres

**Sur le PC d'Astou**, quatre terminaux visibles en même temps :

| | Contenu | Commande |
|---|---|---|
| T1 | la surveillance | `./infra/k8s/watch-deploy-k8s.sh` |
| T2 | preuve de continuité | `while true; do curl -s -o /dev/null -w "%{http_code} " http://localhost/api/version; sleep 0.3; done` |
| T3 | les pods | `kubectl get pods -n tasks -w` |
| T4 | libre | |

Et trois onglets de navigateur : l'application sur `http://localhost`, Grafana
sur `http://localhost:3000`, et l'onglet Actions du dépôt.

**Sur le PC de Chaima** : le dépôt GitHub et un PowerShell dans
`Documents\projet-devops`.

### Préparer la commande à pousser, sans la lancer

```powershell
cd $HOME\Documents\projet-devops
(Get-Content app\frontend\style.css) -replace '--accent: #[0-9a-fA-F]{6}', '--accent: #16a34a' | Set-Content app\frontend\style.css
git add -A
git commit -m "Demonstration : changement de couleur"
git push
```

---

## Le déroulé

### Règle d'or : pousser d'abord, parler ensuite

Entre le `git push` et la nouvelle version en production, il s'écoule deux à
trois minutes — le pipeline, puis le cycle de la surveillance. **Ne restez pas
à regarder l'écran pendant ce temps.** Poussez au début, puis déroulez les
points 5 et l'architecture pendant que ça travaille. Le déploiement
s'annoncera tout seul au moment où vous en parlerez.

---

### 1. Un développeur modifie le code et commit

*Chaima.* Montrer le fichier modifié, puis lancer la commande préparée.

> « Je change la couleur d'accent de l'interface, je commit, je pousse. À
> partir de maintenant, personne ne touche plus à rien. »

### 2. La CI lance les contrôles qualité et les tests

*Chaima.* Onglet **Actions**, ouvrir l'exécution en cours.

> « Le pipeline démarre seul. Job `quality` : analyse statique avec ruff, puis
> 9 tests pytest contre un vrai PostgreSQL fourni par le runner. Si un test
> échoue, rien n'est construit. »

Montrer l'historique : **13 exécutions, 13 vertes**, environ 1 min 10 chacune.

### 3. Les images sont fabriquées et publiées dans un registry

*Chaima.* Job `build`, puis la section **Packages** du dépôt.

> « Deux images, backend et frontend, taguées au SHA du commit, publiées sur
> le registry public de GitHub. La base de données n'a pas d'image à nous :
> on utilise l'image officielle PostgreSQL. »

### 4. Le déploiement se déclenche tout seul

*Astou.* Montrer le terminal T1 **sans rien taper**.

> « Ce script interroge le registry toutes les minutes. Il lit le digest des
> images — leur empreinte unique. Dès qu'elle change, il déclenche la mise à
> jour. GitHub ne peut pas nous joindre, puisque la machine n'a pas d'adresse
> publique : on a donc inversé le sens, c'est la machine qui va chercher.
> C'est le principe du GitOps. »

### 5. L'application tourne sur un cluster Kubernetes

*Pedro*, pendant que le pipeline travaille. Dans T4 :

```bash
kubectl get nodes
kubectl get pods -n tasks -o wide
```

> « k3s est installé directement sur la machine, pas dans des conteneurs. La
> VM, c'est WSL ; le nœud du cluster, c'est cette même machine ; et nos pods
> sont des conteneurs gérés par containerd. Il n'y a aucun emboîtement. »

> « Chaque service tourne en deux répliques. C'est ce qui rend la mise à jour
> sans coupure possible : il y a toujours une réplique disponible pendant que
> l'autre est remplacée. »

### 6. Mise à jour sans coupure

C'est le moment où le déploiement se déclenche. Montrer les trois terminaux :

- **T1** annonce la nouvelle image et la mise à jour progressive
- **T3** montre les pods neufs apparaître, puis les anciens disparaître — jamais tous en même temps
- **T2** n'affiche que des `200`, sans interruption

Puis recharger l'application : la couleur a changé, et le badge de version
affiche le nouveau SHA.

> « Trois éléments le garantissent : deux répliques minimum, `maxUnavailable: 0`
> qui interdit de descendre en dessous, et une `readinessProbe` qui teste
> vraiment la base. Kubernetes démarre un pod neuf, attend qu'il soit prêt, et
> seulement ensuite retire un ancien. »

**Faire une capture d'écran de T2 à ce moment-là.**

### 7. Auto-scaling

*Astou.* Dans T4 :

```bash
kubectl get hpa -n tasks -w
```

Puis, dans un autre terminal :

```bash
kubectl run -n tasks charge --rm -it --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -q -O /dev/null http://backend:8000/api/stats; done'
```

> « On martèle l'endpoint d'agrégation, celui qui fait le calcul SQL. »

Trente secondes plus tard, TARGETS dépasse 70 % et REPLICAS grimpe de 2 vers 6.

Pour montrer la décision écrite :
```bash
kubectl describe hpa backend -n tasks | tail -5
```
> `SuccessfulRescale  New size: 4; reason: cpu resource utilization above target`

Préciser que la descente prend cinq minutes, volontairement, pour éviter un
yoyo de pods.

### 8. On voit tout dans Grafana

*Pedro.* Onglet Grafana, charge toujours active.

> « Les quatre signaux dorés du SRE. Le trafic monte, la latence réagit, le
> taux d'erreur reste à zéro, et la saturation processeur grimpe — c'est elle
> qui a déclenché l'auto-scaling qu'on vient de voir. »

Deux choses à souligner :

> « Les trois premiers signaux viennent de notre code : le backend expose un
> point `/metrics`. Le quatrième vient de cAdvisor, parce qu'une application ne
> peut pas mesurer sa propre saturation. »

> « Et Prometheus ne contient aucune liste de pods : il interroge Kubernetes et
> retient ceux qui portent une annotation. Ajouter une réplique ne demande
> aucune reconfiguration. »

Arrêter la charge avec `Ctrl+C`.

---

## Bonus : résilience, perte d'un pod

Rapide et parlant, à faire avec la boucle `curl` du terminal 2 bien visible.

```bash
kubectl get pods -n tasks
kubectl delete pod -n tasks -l app=backend --wait=false
kubectl get pods -n tasks -w
```

> « Je supprime les deux pods du backend. Personne ne les relance : Kubernetes
> constate que l'état réel ne correspond plus à l'état déclaré — deux répliques
> — et les recrée immédiatement. C'est toute la différence entre lancer un
> conteneur et déclarer un état désiré. »

Le terminal 2 peut afficher quelques erreurs si les deux pods partent
exactement en même temps : c'est honnête à montrer, et c'est l'occasion de dire
que la vraie protection contre ce cas s'appelle un `PodDisruptionBudget`, qui
fait partie de ce qu'il vous reste à mettre en place.

## Les questions probables, et les réponses

**« Pourquoi deux sondes de santé ? »**
`/health/live` ne teste pas la base, `/health/ready` la teste. Si la sonde de
vie testait la base, une indisponibilité momentanée ferait redémarrer en boucle
tous les pods au lieu d'attendre son retour. Et c'est la sonde de disponibilité
qui garantit qu'une nouvelle version ne reçoit du trafic qu'une fois prête.

**« Pourquoi la production ne construit pas les images ? »**
On déploie exactement ce que le pipeline a testé, pas une reconstruction locale
qui pourrait différer. C'est aussi ce qui permet de faire tourner le projet
d'une autre équipe : une seule variable à changer.

**« Comment feriez-vous tourner le projet d'un autre groupe ? »**
En changeant `IMAGE_PREFIX` dans le `.env`. Rien d'autre — aucune adresse,
aucun identifiant n'est écrit en dur dans nos images.

**« Pourquoi pas de secrets ? »**
Consigne du projet, et le dépôt est public. En contexte réel, le mot de passe
vivrait dans un `Secret` Kubernetes ou un gestionnaire dédié. Le principe
essentiel est respecté : la configuration est séparée du code.

**« Pourquoi un seul nœud ? »**
k3s est installé directement sur la machine WSL, sans emboîtement. On aurait pu
simuler plusieurs nœuds avec k3d, mais chacun aurait été un conteneur
privilégié exécutant ses propres conteneurs, et tous auraient partagé le même
noyau — on n'aurait donc pas démontré la résilience à la perte d'une machine,
seulement à celle d'un nœud logique. Avec un nœud réel, l'empilement reste
lisible, et ajouter un second nœud ne demanderait qu'une commande `k3s agent`
sur une autre machine : les manifests sont déjà écrits pour en tirer parti.

**« Qu'est-ce qu'il vous reste à faire ? »**
Les playbooks Ansible pour automatiser l'installation, le déploiement par tag
de version plutôt que par `latest` afin de pouvoir revenir en arrière, les logs
centralisés, et le contrat d'interface avec les équipes SysOps.

---

## Si quelque chose casse

**Le pipeline passe au rouge** — montrer le job en échec et expliquer que c'est
précisément le rôle de la CI : rien n'est publié, la production reste intacte.
Un échec bien géré est une démonstration, pas un accident.

**Un pod ne démarre pas** — `kubectl describe pod <nom> -n tasks`, section
Events en bas.

**Le cluster ne répond plus** — `sudo systemctl restart k3s`, attendre trente
secondes, puis `./infra/k8s/bootstrap.sh` qui est idempotent. Pour comprendre :
`sudo journalctl -u k3s -n 50 --no-pager`.

**Rien ne fonctionne** — la pile Docker Compose reste disponible :
```bash
docker compose -f infra/compose/docker-compose.prod.yml --env-file .env up -d --wait
```
Les points 1 à 4 restent démontrables, et vous expliquez le reste.
