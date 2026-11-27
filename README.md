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

# 7. Deux environnements, deux mécanismes

Le projet se déploie de deux façons, et c'est volontaire.

| | Docker Compose | Kubernetes (k3s) |
|---|---|---|
| Où | `infra/compose/` | `infra/k8s/` |
| Mise à jour | redémarrage des conteneurs | mise à jour progressive, sans coupure |
| Mise à l'échelle | manuelle | automatique (HPA) |
| Rôle | solution de repli, et environnement de staging | la production |

Les deux tirent **les mêmes images** du registry et partagent le même
`app/db/init.sql`. Passer de l'un à l'autre ne change aucune ligne de code.

Garder Docker Compose opérationnel est une sécurité : si le cluster pose
problème, une production reste démontrable en une commande.

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
  k8s/        install-k3s.sh, bootstrap.sh, manifests, watch-deploy-k8s.sh
              monitoring/  Prometheus et Grafana
  ansible/    (à venir)
.github/workflows/
  ci-cd.yml   qualité + build + publication — automatique
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

# 9. Cluster k3s

k3s est installé **directement sur la machine**, pas dans des conteneurs.

```
Machine WSL  =  la VM
Cette machine =  l'unique nœud du cluster
Vos pods      =  conteneurs gérés par containerd, sur cette machine
```

Aucun emboîtement : pas de conteneur-nœud, pas de conteneur dans un conteneur.
k3s s'installe comme un service système ordinaire, géré par systemd.

C'est un choix assumé. Les outils du type k3d ou kind créent des clusters
multi-nœuds en local en faisant tourner chaque nœud dans un conteneur
privilégié, qui exécute lui-même ses propres conteneurs. Ça fonctionne, mais
tous ces nœuds partagent le noyau de l'hôte : on ne démontre alors pas la
résilience à la perte d'une machine, seulement à celle d'un nœud logique.
Ici, l'empilement reste lisible et honnête.

## Installation, une seule fois

```bash
./infra/k8s/install-k3s.sh
```

Le script vérifie que systemd est actif — k3s en a besoin, et sous WSL il faut
parfois l'activer — installe k3s, et configure `kubectl`.

Pour désinstaller : `/usr/local/bin/k3s-uninstall.sh`

## Déployer l'application

```bash
./infra/k8s/bootstrap.sh
```

Le script attend `metrics-server` (inclus dans k3s), applique les manifests,
crée le schéma via un Job dédié, déploie Prometheus et Grafana, puis affiche
l'état. Il est idempotent : relancez-le autant que nécessaire.

Application sur **http://localhost**, Grafana sur **http://localhost:3000**.

## Déploiement continu vers le cluster

```bash
./infra/k8s/watch-deploy-k8s.sh
```

Il interroge le registry, lit le **digest** des images — leur empreinte unique —
et déclenche un `kubectl set image` dès qu'elle change. Deux raisons d'épingler
le digest plutôt que le tag `latest` : un tag peut changer de contenu sans
prévenir, alors qu'un digest désigne un contenu précis pour toujours ; et comme
la valeur change réellement, Kubernetes déclenche la mise à jour.

En cas d'échec, le script restaure la version précédente avec
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
et seulement ensuite retire un ancien pod. Deux répliques suffisent, même sur
un seul nœud — ce qui est démontré ici, c'est la continuité pendant un
déploiement, pas la tolérance à la panne d'une machine.

### Auto-scaling

```bash
kubectl get hpa -n tasks -w

kubectl run -n tasks charge --rm -it --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -q -O /dev/null http://backend:8000/api/stats; done'
```

Le nombre de répliques monte de 2 vers 6 quand l'utilisation processeur dépasse
70 % de la demande, puis redescend après cinq minutes de calme.

Pour voir la décision écrite :
```bash
kubectl describe hpa backend -n tasks | tail -5
```

### Résilience : perte d'un pod

```bash
kubectl get pods -n tasks
kubectl delete pod -n tasks -l app=backend --field-selector status.phase=Running --wait=false
kubectl get pods -n tasks -w
```

Kubernetes recrée immédiatement les pods supprimés pour revenir au nombre
demandé. Avec la boucle `curl` ouverte à côté, on voit que le service ne
s'interrompt pas : l'autre réplique absorbe le trafic le temps que la nouvelle
démarre.

C'est la différence entre un conteneur et un pod géré : personne ne relance
quoi que ce soit, l'état désiré est déclaré et Kubernetes le maintient.

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

## Deux pièges rencontrés, et leur correction

**Le panneau Saturation restait vide.** Prometheus collecte cAdvisor en passant
par le proxy de l'API Kubernetes, ce qui exige la permission `nodes/proxy` dans
le ClusterRole. Sans elle il reçoit un `403`, et ce signal seul reste vide
pendant que tous les autres fonctionnent — un symptôme trompeur, puisqu'on
soupçonne d'abord la requête.

**Le panneau Erreurs affichait « aucune donnée ».** Quand il n'y a aucune
réponse 5xx, la requête ne renvoie pas zéro : elle ne renvoie *rien*. Un
`or vector(0)` force la valeur à zéro, ce qui est la bonne lecture — zéro
erreur est une information, l'absence de donnée n'en est pas une.

Les sondes de santé de Kubernetes sont par ailleurs exclues des panneaux trafic
et latence : interrogées toutes les cinq secondes, elles écrasaient le trafic
réel des utilisateurs.

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
