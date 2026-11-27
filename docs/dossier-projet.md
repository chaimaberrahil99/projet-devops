# Dossier de projet — Déploiement continu d'une application multi-composants

**Équipe :** Berrahil Chaima · Thiam Astou · Gomes Pinto Pedro
**Dépôt :** https://github.com/chaimaberrahil99/projet-devops
**Date :** 27 novembre 2026

---

## 1. Architecture déployée

L'application est découpée en trois composants, chacun isolé dans son conteneur :

| Composant | Techno | Rôle |
|---|---|---|
| Frontend | HTML/JS servi par Nginx | interface et tableau de bord ; relaie `/api` vers le backend |
| Backend | Python / FastAPI | API REST, agrégations SQL, sondes de santé, métriques |
| Base de données | PostgreSQL 16 | 240 lignes sur 6 catégories et 90 jours |

### La chaîne, de bout en bout

```
  poste du développeur
          │  git push
          ▼
  GitHub Actions ─── ruff ─── 9 tests pytest (PostgreSQL réel)
          │
          │  si tout passe
          ▼
  GHCR  (registry public)  ·  2 images taguées au SHA du commit
          │
          │  interrogé toutes les minutes
          ▼
  machine de production ─── lecture du digest ─── kubectl set image
          │
          ▼
  cluster k3s ─── mise à jour progressive, sans coupure
          │
          ├── 2 pods backend     ── /metrics ──┐
          ├── 2 pods frontend                  │
          └── 1 pod PostgreSQL (StatefulSet)   │
                                               ▼
                             Prometheus ──► Grafana (4 signaux SRE)
```

La machine de production ne connaît jamais le code source : seulement des
images versionnées, tirées du registry.

### Les deux environnements

| | Staging | Production |
|---|---|---|
| Outil | Docker Compose | Kubernetes (k3s) |
| Images | construites localement | tirées du registry |
| Mise à jour | manuelle, `up --build` | automatique, progressive |
| Mise à l'échelle | aucune | automatique, 2 à 6 pods |
| Rôle | développer et tester | servir, et démontrer |

Les deux partagent le même code et le même `app/db/init.sql`. Docker Compose
reste opérationnel : c'est la solution de repli si le cluster pose problème.

### Le support

k3s est installé **directement** sur une machine WSL, sans emboîtement : la VM
est WSL, le nœud du cluster est cette même machine, et les pods sont des
conteneurs gérés par containerd.

Nous avions d'abord monté un cluster multi-nœuds avec k3d, où chaque nœud est
un conteneur privilégié exécutant ses propres conteneurs. Nous l'avons
abandonné : ces nœuds partagent le noyau de l'hôte, on n'y démontre donc pas
la résilience à la perte d'une machine. Ajouter un vrai second nœud ne
demanderait qu'une commande `k3s agent` sur une autre machine — les manifests
sont déjà écrits pour en tirer parti.

---

## 2. Choix techniques

| Sujet | Choix | Justification |
|---|---|---|
| Application | 3 composants, périmètre volontairement minimal | la note porte sur la chaîne DevOps, pas sur l'applicatif ; une application simple rend le débogage de l'infrastructure lisible |
| Base de données | PostgreSQL 16, image officielle | seul composant *stateful*, traité à part : volume persistant, et `StatefulSet` dans les manifests Kubernetes |
| Portabilité | configuration 100 % par variables d'environnement | aucune adresse ni identifiant figé dans les images : les mêmes images tournent sur n'importe quelle infrastructure |
| Secrets | aucun, valeurs factices versionnées | consigne explicite, et dépôt public : le projet est clonable et lançable tel quel par une autre équipe |
| Sondes de santé | deux sondes distinctes | `/health/live` ne teste pas la base, `/health/ready` la teste — voir section 3 |
| CI/CD | GitHub Actions | fichier YAML versionné (contrainte d'IaC respectée), aucun serveur à héberger, aucun secret à configurer |
| Registry | GHCR (GitHub Container Registry) | authentification par le `GITHUB_TOKEN` automatique, zéro configuration |
| Production | Kubernetes (k3s), nœud unique | k3s est du vrai Kubernetes, installable en une commande, et embarque `metrics-server` et `servicelb` ; installé directement sur la machine, sans emboîtement |
| Staging | Docker Compose | construit depuis les sources, sert aussi de solution de repli |
| Déploiement continu | surveillance du registry, en mode « tiré » | la machine n'a pas d'adresse publique, GitHub ne peut donc pas la joindre ; on inverse le flux — principe du GitOps |
| Version déployée | épinglage par digest | un tag peut changer de contenu, un digest désigne un contenu précis pour toujours |
| Zéro-interruption | 2 répliques, `maxUnavailable: 0`, `readinessProbe` réelle | les trois sont nécessaires : sans l'une, la coupure revient |
| Auto-scaling | HPA sur le processeur, 2 à 6 pods, seuil 70 % | 70 % et non 90 % pour laisser aux nouveaux pods le temps de démarrer |
| Observabilité | Prometheus et Grafana, 4 signaux SRE | métriques applicatives exposées par le code, saturation mesurée par cAdvisor |
| Découverte des cibles | annotations sur les pods | aucune liste à tenir à jour : ajouter une réplique ne demande aucune reconfiguration |
| Migrations | Job dédié, script SQL idempotent | jamais jouées au démarrage de l'application (voir section 3) |

---

## 3. Difficultés rencontrées et solutions

**Images Docker privées par défaut.** Le pipeline publiait correctement les deux
images sur GHCR, mais GitHub les crée en visibilité privée même depuis un dépôt
public. La machine de production recevait une erreur `denied` au téléchargement.
*Solution :* basculer chaque package en `Public` depuis ses réglages, puis
vérifier depuis une fenêtre de navigation privée que la page s'affiche sans
authentification. Cette étape est documentée dans le README, car elle est
invisible et bloquante.

**Docker Desktop instable sous Windows.** Sur un poste de l'équipe, Docker
Desktop s'est arrêté avec `service dockerd failed: exit status 1`, un problème
lié à WSL. *Solution :* ne pas engager de temps dans le diagnostic et déplacer le
travail vers les postes fonctionnels. La vérification de visibilité des images,
initialement prévue avec `docker pull`, a été faite par le navigateur.

**Clone impossible dans un dossier système.** Un `git clone` lancé depuis
`C:\WINDOWS\system32` a échoué sur `Permission denied`. *Solution :* se placer
dans un dossier utilisateur avant de cloner. Anecdotique, mais typique du temps
perdu sur des détails d'environnement plutôt que sur le fond.

**Script de seed non idempotent.** Le script de migration est rejoué à chaque
déploiement. La protection initiale par `ON CONFLICT DO NOTHING` était
inopérante : la clef primaire étant un `SERIAL`, aucun conflit n'est détectable
et chaque exécution aurait dupliqué les données. *Solution :* conditionner
l'insertion par un `WHERE NOT EXISTS`, vérifié en rejouant le script trois fois
de suite.

**Casse des noms d'images.** GHCR refuse les majuscules dans un nom d'image,
alors que la variable GitHub qui porte le nom du dépôt conserve sa casse.
*Solution :* une conversion en minuscules dans le pipeline, avant la
construction.

**Contrainte de temps.** Le premier jalon imposait une application, une CI/CD et
une production fonctionnelles en moins de trois heures, avec une équipe
découvrant Docker. *Solution :* arbitrage explicite — abandon de Kubernetes
(non obligatoire) au profit d'une production Docker Compose réellement
opérationnelle. Les manifests Kubernetes restent dans le dépôt pour la suite.

---

**Intégration WSL de Docker désactivée.** Docker Desktop expose la commande
`docker` à Windows, mais pas automatiquement à l'intérieur d'une distribution
WSL. Les commandes échouaient, et notre script de surveillance masquait
l'erreur réelle derrière un message trompeur. *Solution :* activer
l'intégration dans Docker Desktop, et surtout corriger le script pour qu'il
affiche le message exact plutôt que de le supprimer. Un script qui cache les
erreurs coûte plus cher qu'il ne rapporte.

**Un `git pull` refusé par une modification locale.** Une coéquipière avait
modifié `.env` à la main ; la même valeur a ensuite été committée. Git a refusé
la fusion, et le script attendu n'a jamais été téléchargé — l'erreur suivante,
« No such file or directory », pointait donc ailleurs que la cause.
*Solution :* `git checkout -- .env`, puis committer la valeur par défaut dans
le dépôt pour que le cas ne se reproduise plus.

**Permission `nodes/proxy` manquante pour Prometheus.** Un seul panneau de
Grafana restait vide, celui de la saturation, pendant que les trois autres
fonctionnaient — symptôme trompeur, on soupçonne d'abord la requête. La cause
était trois niveaux plus loin : la collecte cAdvisor passe par le proxy de
l'API Kubernetes, ce qui exige un droit que notre ClusterRole n'accordait pas.
*Solution :* ajouter `nodes/proxy`, et prendre le réflexe de vérifier la page
`/targets` de Prometheus avant de soupçonner le tableau de bord.

**« Aucune donnée » au lieu de zéro.** Sans aucune réponse 5xx, la requête du
taux d'erreur ne renvoyait pas zéro : elle ne renvoyait rien. *Solution :*
`or vector(0)`. Zéro erreur est une information, l'absence de donnée n'en est
pas une.

**Un cluster qui répond n'est pas un cluster prêt.** Notre script de
déploiement échouait sur `metrics-server not found` : k3s crée ce composant
plusieurs dizaines de secondes après que le nœud passe en `Ready`.
*Solution :* attendre explicitement que la ressource existe avant d'en vérifier
l'état, au lieu de le supposer.

**Les ports de k3s ne sont pas relayés par WSL.** Depuis WSL, l'application
répondait ; depuis le navigateur Windows, rien. WSL relaie les ports sur
lesquels un processus **écoute** réellement, or k3s installe des règles de
routage dans le pare-feu, qu'il ne détecte pas. Avec Docker Compose la question
ne se posait pas, Docker Desktop lançant un processus côté Windows.
*Solution :* accéder à l'application par l'adresse IP de la machine WSL
(`hostname -I`). Nous avons écarté `kubectl port-forward`, qui rétablirait
`localhost` mais court-circuite l'exposition réelle du service.

**Architecture du cluster revue en cours de route.** Nous avions d'abord monté
un cluster multi-nœuds avec k3d, où chaque nœud est un conteneur privilégié
exécutant ses propres conteneurs. L'encadrant a écarté cet emboîtement, et
l'argument technique nous a convaincus : ces nœuds partagent le noyau de
l'hôte, on n'y démontre donc pas la résilience à la perte d'une machine.
*Solution :* installer k3s directement sur la machine WSL, avec un nœud unique.
Nos manifests n'ont demandé aucune modification.

## 4. Points techniques à défendre

**Pourquoi deux sondes de santé.** `/health/live` répond tant que le processus
vit, sans interroger la base. `/health/ready` interroge la base et renvoie `503`
si elle est injoignable. Si la sonde de vie testait la base, une indisponibilité
momentanée ferait redémarrer en boucle tous les conteneurs du backend au lieu
d'attendre son retour. C'est également la sonde de disponibilité qui garantit
qu'une nouvelle version ne reçoit du trafic qu'une fois réellement opérationnelle
— la condition du déploiement sans interruption.

**Pourquoi la production ne construit rien.** Elle tire des images déjà
construites et testées par le pipeline. On déploie donc exactement ce qui a été
validé, et non une reconstruction locale potentiellement différente. C'est aussi
ce qui permet de déployer le projet d'une autre équipe sur cette même
infrastructure : une seule variable à changer.

**Pourquoi les migrations sont séparées.** Si le backend appliquait le schéma à
son démarrage, plusieurs instances démarrant en parallèle lors d'une mise à jour
migreraient simultanément. Le schéma est donc appliqué par une étape dédiée,
avant la mise à jour applicative. Corollaire respecté dans le script : pendant
une mise à jour progressive, l'ancienne et la nouvelle version coexistent sur le
même schéma, donc on ajoute des colonnes sans jamais en renommer ni en supprimer.

---

## 5. Répartition des rôles

| Membre | Rôle | Réalisations |
|---|---|---|
| **Berrahil Chaima** | Dépôt Git et CI/CD | création du dépôt public, mise en place du pipeline GitHub Actions (analyse statique, tests, construction et publication des images), configuration du registry et de la visibilité des packages |
| **Thiam Astou** | Infrastructure et production | préparation de la machine, Docker puis k3s, déploiement de la stack et de la supervision, diagnostic de l'intégration WSL et de l'accès réseau, service systemd, exploitation au quotidien |
| **Gomes Pinto Pedro** | Staging et validation | environnement de développement construit depuis les sources, validation des trois composants, seconde instance démontrant la portabilité, correction de la commande de démonstration du redémarrage automatique |

Documentation et dossier de projet : rédaction commune.

---

## 6. Reste à faire

Par ordre d'importance.

**Déploiement par tag de version.** C'est notre principale faiblesse : on
déploie toujours la dernière image, sans pouvoir revenir à celle d'hier. Les
images portent pourtant déjà un tag au SHA du commit — il suffirait de piloter
le déploiement par ce tag.

**Playbooks Ansible** pour automatiser l'installation de la machine. Aujourd'hui,
`install-k3s.sh` et `bootstrap.sh` font le travail, mais ce sont des scripts,
pas de l'infrastructure déclarative.

**Un second nœud**, pour démontrer la résilience à la perte d'une machine et
non seulement d'un pod. Une commande `k3s agent` suffirait ; les manifests
contiennent déjà la contrainte de répartition.

**Un `PodDisruptionBudget`**, pour garantir un minimum de pods disponibles
pendant les opérations de maintenance.

**Logs centralisés** avec Loki, qui s'affiche dans la Grafana déjà en place.

**Le contrat d'interface avec les équipes SysOps** : ports exposés, variables
d'environnement attendues, chemins des sondes de santé, registry utilisée.
C'est la condition pour que nos conteneurs tournent sur leur infrastructure et
réciproquement.
