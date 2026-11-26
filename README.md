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
