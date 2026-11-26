# Dossier de projet — Déploiement continu d'une application multi-composants

**Équipe :** Berrahil Chaima · Thiam Astou · Gomes Pinto Pedro
**Dépôt :** https://github.com/chaimaberrahil99/projet-devops
**Date :** 26 novembre 2026

---

## 1. Architecture déployée

L'application est découpée en trois composants, chacun isolé dans son propre
conteneur :

| Composant | Techno | Rôle |
|---|---|---|
| Frontend | HTML/JS servi par Nginx | interface et tableau de bord ; relaie `/api` vers le backend |
| Backend | Python / FastAPI | API REST, agrégations SQL, sondes de santé |
| Base de données | PostgreSQL 16 | 240 lignes sur 6 catégories et 90 jours |

**Deux environnements**, construits à partir du même code :

- **Staging** — `docker compose` en local, images construites sur place.
- **Production** — `docker compose` sur VM, images **tirées du registry**, jamais
  construites sur place.

**Chaîne complète :** un commit déclenche le pipeline, qui joue l'analyse
statique et les tests, construit les deux images Docker et les publie sur GHCR.
La production télécharge ensuite ces images depuis le registry. La machine de
production ne connaît jamais le code source, uniquement des images versionnées.

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
| Production | Docker Compose sur VM | Kubernetes non obligatoire ; une production qui fonctionne a été préférée à un cluster incomplet dans le temps imparti |
| Kubernetes | manifests écrits, déploiement en workflow manuel | prêts pour la suite, volontairement non activés |
| Migrations | script SQL séparé et idempotent | jamais jouées au démarrage de l'application (voir section 3) |

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
| **Thiam Astou** | Infrastructure et production | préparation de la machine de production, installation de Docker, déploiement de la stack applicative, vérification de la résilience |
| **Gomes Pinto Pedro** | Application et validation | exécution de l'environnement de staging, validation du fonctionnement des trois composants, préparation et répétition de la démonstration |

Documentation et dossier de projet : rédaction commune.

---

## 6. Reste à faire

- Playbooks Ansible pour automatiser l'installation de l'environnement
- Bascule vers Kubernetes (manifests déjà écrits, `metrics-server` requis pour l'auto-scaling)
- Observabilité : Prometheus et Grafana, en coordination avec les équipes SysOps
- Logs centralisés (Loki)
- Contrat d'interface commun avec les autres équipes : ports exposés, variables
  d'environnement attendues, chemins des sondes de santé, registry utilisée
