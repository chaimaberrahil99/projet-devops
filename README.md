# Projet DevOps — Application multi-composants

Trois composants, un pipeline CI/CD, une production sur VM.

| Composant | Techno | Rôle |
|---|---|---|
| `app/frontend` | HTML/JS + Nginx | interface et tableau de bord ; relaie `/api` vers le backend |
| `app/backend` | Python / FastAPI | API REST, agrégations, sondes de santé |
| `app/db` | PostgreSQL 16 | 240 lignes de données, 6 catégories |

**Aucun secret dans ce projet.** Le dépôt est public, le mot de passe est
factice et volontairement versionné dans `.env` : n'importe qui peut cloner et
lancer le projet sans rien configurer. En contexte réel, ce mot de passe
vivrait dans un Secret Kubernetes — c'est signalé à chaque endroit concerné.

---

# 1. Lancer en local (staging)

```bash
cd infra/compose
docker compose --env-file ../../.env up --build
```

Application sur <http://localhost:8080>.

---

# 2. Mettre en place la CI/CD

Le pipeline (`.github/workflows/ci-cd.yml`) tourne **sans aucune
configuration** : pas de secret à créer, rien à paramétrer. GHCR s'authentifie
avec le `GITHUB_TOKEN` fourni automatiquement par GitHub.

```bash
git init && git add -A && git commit -m "Projet DevOps : application, CI/CD, production"
git remote add origin https://github.com/<vous>/<depot>.git
git push -u origin main
```

Le pipeline démarre seul. Deux jobs enchaînés :

| Job | Rôle |
|---|---|
| `quality` | `ruff` (analyse statique) + `pytest` contre un **vrai** PostgreSQL |
| `build` | construit et publie les 2 images, taguées au SHA du commit |

Rien ne se construit si le lint ou les tests échouent.

### ÉTAPE MANUELLE OBLIGATOIRE — rendre les images publiques

GitHub publie les images en **privé** par défaut, même depuis un dépôt public.
Sans cette étape, la VM ne pourra pas les télécharger.

Après le premier passage du pipeline, pour **chacune** des deux images :
page du dépôt → **Packages** (colonne de droite) → cliquer sur l'image →
**Package settings** → **Change visibility** → **Public**.

C'est aussi ce qui permettra aux autres équipes de déployer vos images.

---

# 3. Déployer en production sur la VM

### ÉTAPES MANUELLES sur la VM

```bash
# 1. Docker, s'il n'est pas déjà installé
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# 2. Récupérer le projet
git clone https://github.com/<vous>/<depot>.git && cd <depot>

# 3. Renseigner le préfixe d'images dans .env, EN MINUSCULES
#    IMAGE_PREFIX=ghcr.io/<vous>/<depot>
nano .env

# 4. Déployer
./infra/compose/deploy.sh
```

Application accessible sur `http://<ip-de-la-VM>/`.

Pour déployer une version précise plutôt que la dernière :
```bash
./infra/compose/deploy.sh sha-a1b2c3d
```

### Pourquoi la prod ne construit rien

`docker-compose.prod.yml` ne contient aucune directive `build` : il **tire** les
images publiées par le pipeline. La VM ne connaît pas le code source, seulement
des images versionnées. C'est ce qui fait de ce déploiement un vrai déploiement
continu — et ce qui permet de faire tourner le projet d'une **autre équipe** sur
cette même infrastructure, en changeant simplement `IMAGE_PREFIX`.

---

# 4. Résilience — à démontrer en direct

Trois mécanismes, chacun vérifiable en une commande.

**Redémarrage automatique.** Tous les services sont en `restart: unless-stopped`.
```bash
docker kill $(docker compose -f infra/compose/docker-compose.prod.yml ps -q backend)
docker compose -f infra/compose/docker-compose.prod.yml ps   # il est déjà revenu
```

**Persistance des données.** La base vit dans un volume nommé.
```bash
docker compose -f infra/compose/docker-compose.prod.yml down   # sans -v !
./infra/compose/deploy.sh                                       # les 240 lignes sont là
```

**Démarrage ordonné.** Le backend n'attend pas que la base soit *démarrée* mais
qu'elle soit *prête* (`condition: service_healthy`), et le frontend attend que
le backend soit prêt. Au reboot de la VM, tout remonte dans le bon ordre sans
intervention.

### Les deux sondes de santé, et pourquoi elles sont deux

- `GET /health/live` — le processus répond. **Ne teste pas la base.**
- `GET /health/ready` — le service peut répondre. **Teste la base**, renvoie `503` sinon.

Si la sonde de vie testait la base, une base momentanément indisponible ferait
redémarrer en boucle tous les conteneurs du backend au lieu d'attendre son
retour. C'est la distinction qui rend les mises à jour sans interruption
possibles.

Vérification :
```bash
docker compose -f infra/compose/docker-compose.prod.yml stop db
curl -i http://localhost/api/version      # le frontend répond toujours
docker compose -f infra/compose/docker-compose.prod.yml start db
```

---

# 5. La donnée

La base contient **240 lignes** sur 6 catégories et 90 jours, générées par
`app/db/init.sql`.

`GET /api/stats` renvoie les agrégations, **calculées par PostgreSQL** et non en
Python : le SQL réduit 240 lignes à 6 et renvoie quelques centaines d'octets,
là où tout remonter pour compter côté applicatif ferait transiter la table
entière à chaque appel. Le tableau de bord du frontend affiche ces agrégations.

Le script de seed est **idempotent** : il est rejoué à chaque déploiement sans
dupliquer les données. Attention au piège, un `ON CONFLICT DO NOTHING` ne
suffit pas quand la clef est un `SERIAL` — il n'y a aucun conflit à détecter.

---

# 6. Tests

```bash
cd app/backend
pip install -r requirements-dev.txt
ruff check .
pytest
```

9 tests. Trois ne nécessitent **aucune** base : le pipeline a toujours quelque
chose de vert. Les six autres se désactivent automatiquement si la base est
absente, et tournent pour de vrai en CI grâce au service PostgreSQL du job.

---

# 7. Kubernetes — pour plus tard

Les manifests sont prêts dans `infra/k8s/` (`StatefulSet` pour la base,
Deployments avec `maxUnavailable: 0`, `HorizontalPodAutoscaler`, Job de
migration), et le workflow `deploy-k8s.yml` les applique. Ils ne sont **pas
utilisés** par la production actuelle, qui tourne en Docker Compose.

Pour y passer : un cluster joignable, le secret de dépôt `KUBE_CONFIG`
(`base64 -w0 ~/.kube/config`), et `metrics-server` installé sur le cluster —
sans lui l'HPA reste bloqué sur `<unknown>`. Puis onglet Actions →
*Déploiement Kubernetes* → *Run workflow*.

---

# Arborescence

```
app/
  frontend/   Dockerfile, index.html, app.js, style.css, nginx.conf.template
  backend/    Dockerfile, main.py, requirements*.txt, pyproject.toml, tests/
  db/         init.sql  (schéma + 240 lignes, idempotent)
infra/
  compose/    docker-compose.yml (staging)
              docker-compose.prod.yml (production VM)
              deploy.sh (déploiement en une commande)
  k8s/        manifests Kubernetes (pour plus tard)
  ansible/    (à venir)
.github/workflows/
  ci-cd.yml        qualité + build + publication  — automatique
  deploy-k8s.yml   déploiement Kubernetes         — manuel
docs/         dossier de projet
.env          configuration, volontairement versionnée (aucun secret)
```


---

# 8. Déploiement continu « tiré » (pull-based)

Le pipeline s'exécute sur les serveurs de GitHub. Pour qu'il déploie lui-même
sur une machine, il faudrait qu'il puisse s'y connecter — impossible si celle-ci
n'a pas d'adresse publique : PC derrière une box, réseau d'école, VM locale.

On inverse donc le sens. Ce n'est plus GitHub qui pousse vers la machine, c'est
la machine qui va chercher : elle interroge le registry toutes les deux minutes
et redéploie dès qu'une nouvelle image est publiée. Aucun port à ouvrir, aucune
adresse publique nécessaire.

C'est le principe du **GitOps** — celui de FluxCD et ArgoCD cités dans le sujet —
réduit à sa plus simple expression.

## Lancer la surveillance

Sur la machine de production, depuis la racine du dépôt :

```bash
./infra/compose/watch-deploy.sh
```

Le script démarre la stack, puis boucle. À chaque cycle il compare l'identifiant
local des images avant et après un `pull` : s'il a changé, une nouvelle version
a été publiée, et il redéploie avec `up -d --wait` suivi des migrations.

Pour tester plus vite : `INTERVALLE=30 ./infra/compose/watch-deploy.sh`

## En faire un service permanent

Pour qu'il survive à la fermeture du terminal et au redémarrage de la machine :

```bash
sudo cp infra/systemd/projet-devops-watch.service /etc/systemd/system/
sudo nano /etc/systemd/system/projet-devops-watch.service   # adapter User= et WorkingDirectory=
sudo systemctl daemon-reload
sudo systemctl enable --now projet-devops-watch
```

Suivre ce qu'il fait, en direct :
```bash
journalctl -u projet-devops-watch -f
```

Sous WSL, `systemd` n'est pas toujours actif. Dans ce cas, lancer le script en
arrière-plan suffit :
```bash
nohup ./infra/compose/watch-deploy.sh > /tmp/watch-deploy.log 2>&1 &
tail -f /tmp/watch-deploy.log
```

## Démonstration de la chaîne complète

Avec ce service en marche, le scénario décrit dans les consignes se déroule sans
aucune intervention humaine :

1. Un développeur modifie le code et pousse un commit.
2. Le pipeline joue l'analyse statique et les tests.
3. Les images sont construites et publiées sur le registry.
4. La machine de production détecte la nouvelle version et redéploie seule.

Comptez trois à quatre minutes entre le `git push` et la nouvelle version en
ligne. Gardez `journalctl -u projet-devops-watch -f` affiché pendant la
démonstration : on y voit le redéploiement se déclencher tout seul.

## Pourquoi pas un runner auto-hébergé

L'autre solution consisterait à installer un agent GitHub Actions sur la machine,
qui interroge GitHub en sortie. Elle est écartée ici volontairement : sur un
dépôt **public**, n'importe qui peut ouvrir une pull request dont le code
s'exécuterait sur la machine hôte. GitHub le déconseille explicitement. Le
déploiement tiré n'a pas ce défaut, puisque la machine ne fait que télécharger
des images.


---

# 9. Cluster k3s local (multi-nœuds)

La production décrite plus haut tourne en Docker Compose. Cette section décrit
le déploiement sur un cluster **k3s**, monté en local avec **k3d**.

## Pourquoi k3d, et pourquoi plusieurs nœuds

k3d lance k3s dans des conteneurs Docker : un serveur et deux agents, chacun
avec son propre kubelet. Kubernetes les traite comme des machines distinctes —
planification, répartition des pods et vidange d'un nœud fonctionnent
réellement.

Un cluster n'a d'intérêt que s'il répartit la charge entre plusieurs machines :
on peut alors montrer qu'un nœud tombe sans que le service s'interrompe. C'est
impossible avec le Kubernetes mono-nœud de Docker Desktop.

À dire tel quel : ce sont des conteneurs, pas des machines virtuelles, mais la
distribution est bien k3s et le cluster est authentiquement multi-nœuds. Le
passage à de vraies VM ne change que le support — mêmes manifests, mêmes
commandes, même distribution.

Deux avantages pratiques de k3s : `metrics-server` est inclus d'origine, donc
l'auto-scaling fonctionne sans rien installer ; et `servicelb` fournit les
services de type LoadBalancer, qui exposent l'application sur le port 80.

## Prérequis

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl

k3d version && kubectl version --client
```

## Tout monter en une commande

```bash
./infra/k8s/bootstrap.sh
```

Le script crée le cluster, attend `metrics-server`, déploie l'application,
applique le schéma via un Job dédié, et affiche la répartition des pods.
Comptez cinq à dix minutes au premier lancement.

Application sur **http://localhost**.

Pour repartir de zéro : `k3d cluster delete projet-devops`

## Déploiement continu vers le cluster

```bash
./infra/k8s/watch-deploy-k8s.sh
```

Il interroge le registry, lit le **digest** des images — leur empreinte unique —
et déclenche un `kubectl set image` dès qu'elle change. Deux raisons d'épingler
le digest plutôt que le tag `latest` : un tag peut changer de contenu sans
prévenir, alors qu'un digest désigne un contenu précis pour toujours ; et
comme la valeur change réellement, Kubernetes déclenche la mise à jour.

En cas d'échec du déploiement, le script restaure la version précédente avec
`kubectl rollout undo`.

## Les trois démonstrations

### Mise à jour sans interruption

```bash
# Terminal 1 : preuve de la continuité de service
while true; do curl -s -o /dev/null -w "%{http_code} " http://localhost/api/version; sleep 0.3; done

# Terminal 2 : les pods remplacés un par un
kubectl get pods -n tasks -w
```

Poussez un commit. Le badge de version bascule dans l'interface, le terminal 1
n'affiche que des `200`, et le terminal 2 montre les anciens pods remplacés
progressivement.

Ce qui le garantit : `replicas: 2`, `maxUnavailable: 0` et `maxSurge: 1`.
Kubernetes démarre un pod neuf, attend que sa `readinessProbe` passe au vert,
et seulement ensuite retire un ancien pod.

### Auto-scaling

```bash
kubectl get hpa -n tasks -w

kubectl run -n tasks charge --rm -it --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -q -O- http://backend:8000/api/stats; done'
```

Le nombre de répliques monte de 2 vers 6 quand l'utilisation processeur dépasse
70 % de la demande, puis redescend après cinq minutes de calme.

### Résilience : perte d'un nœud

```bash
kubectl get nodes
kubectl get pods -n tasks -o wide          # voir la répartition

kubectl drain k3d-projet-devops-agent-0 --ignore-daemonsets --delete-emptydir-data
kubectl get pods -n tasks -o wide          # tout a migré sur l'autre nœud
```

L'application continue de répondre pendant toute l'opération. Pour remettre le
nœud en service : `kubectl uncordon k3d-projet-devops-agent-0`.

Vérifiez le nom exact du nœud avec `kubectl get nodes` avant de lancer le
`drain`.

C'est la contrainte `topologySpreadConstraints` des Deployments qui répartit les
répliques sur des nœuds différents — sans elle, les deux pourraient se retrouver
sur la même machine, et sa perte couperait le service malgré les deux répliques.


---

# 10. Observabilité — Prometheus et Grafana

Déployés automatiquement par `bootstrap.sh`, dans le namespace `monitoring`.

**Grafana : <http://localhost:3000>** — consultation libre, sans connexion. Le
tableau de bord « Projet DevOps - les 4 signaux SRE » est déjà là.

## Les quatre signaux

| Signal | Ce qu'il mesure | D'où vient la donnée |
|---|---|---|
| Trafic | requêtes par seconde, par route | compteur exposé par le backend |
| Erreurs | proportion de réponses 5xx | même compteur, filtré sur le code |
| Latence | 95e centile du temps de réponse | histogramme exposé par le backend |
| Saturation | processeur consommé par pod | cAdvisor, intégré au kubelet |

Les trois premiers viennent du code : le backend expose `/metrics`, avec un
compteur `http_requests_total` et un histogramme
`http_request_duration_seconds`. Le quatrième vient de Kubernetes, car une
application ne peut pas mesurer sa propre saturation.

## Deux décisions à savoir défendre

**On expose des séries, pas des moyennes déjà calculées.** Le backend se
contente d'incrémenter des compteurs ; c'est Prometheus qui calcule les taux au
moment de la requête. On peut donc demander « le taux d'erreur des cinq
dernières minutes » sans que l'application ait eu à le prévoir.

**On mesure la latence par centile, pas par moyenne.** Une moyenne masque les
requêtes lentes : si 99 requêtes prennent 10 ms et une seule 3 secondes, la
moyenne reste à 40 ms alors qu'un utilisateur sur cent attend trois secondes.
Le 95e centile dit « 95 % des utilisateurs sont servis plus vite que ça ».

## La découverte automatique des cibles

Prometheus ne contient aucune liste de pods. Il interroge Kubernetes et retient
ceux qui portent l'annotation `prometheus.io/scrape: "true"` — elle est posée
sur le Deployment du backend. Ajouter une réplique, ou un nouveau service, ne
demande donc aucune modification de la configuration de Prometheus.

## Vérifier que la collecte fonctionne

```bash
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```
Puis <http://localhost:9090/targets> : les cibles `application` et `cadvisor`
doivent être en `UP`.

## Faire bouger les courbes pendant la démonstration

```bash
kubectl run -n tasks charge --rm -it --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -q -O- http://backend:8000/api/stats; done'
```

Le trafic monte, la latence réagit, la saturation processeur grimpe — et
l'auto-scaling se déclenche. Les quatre signaux racontent la même histoire au
même moment : c'est exactement ce qu'on attend d'un tableau de bord SRE.
