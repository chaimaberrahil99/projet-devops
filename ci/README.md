# ci/

Dossier conservé pour coller à la structure suggérée par le sujet
(`/app`, `/infra`, `/ci`).

La configuration du pipeline vit en réalité dans **`.github/workflows/ci-cd.yml`** :
GitHub Actions impose cet emplacement, il n'est pas négociable. La contrainte
d'Infrastructure-as-Code est respectée de la même façon — le pipeline est un
fichier YAML versionné dans le dépôt.

Si vous basculez sur Jenkins, le `Jenkinsfile` ira ici.
