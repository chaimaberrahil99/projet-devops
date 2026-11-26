# Dossier de projet

> À remplir au fur et à mesure. Le sujet demande explicitement ces quatre
> sections. Les rédiger en continu coûte dix minutes par semaine ; les rédiger
> la veille de la soutenance coûte une nuit.

## 1. Architecture déployée

(Schéma des composants, des environnements staging/production, des flux réseau.)

## 2. Choix techniques

| Sujet | Choix | Justification |
|---|---|---|
| Application | 3 composants : Nginx statique / FastAPI / PostgreSQL | périmètre minimal, build rapide, débogage de l'infra non parasité par l'applicatif |
| Base de données | PostgreSQL 16 | image officielle, `StatefulSet` + PVC en production |
| Portabilité | configuration 100 % par variables d'environnement | la même image tourne sur n'importe quelle infra SysOps |
| Sondes | liveness sans base / readiness avec base | évite les redémarrages en boucle, conditionne le zéro-downtime |
| IaC | Ansible (obligatoire) | |
| CI/CD | | |
| Observabilité | Prometheus + Grafana + cAdvisor | |
| Logs | | |

## 3. Difficultés rencontrées et solutions

(Tenir un journal daté. C'est la section la plus valorisée en soutenance, et
celle qu'on ne peut pas reconstituer après coup.)

## 4. Répartition des rôles

| Membre | Rôle principal | Étapes |
|---|---|---|
| | Dev / applicatif | 1, 2 |
| | Ops / IaC | 4, 6 |
| | CI/CD | 5 |
| | Observabilité | 8, 9 |
