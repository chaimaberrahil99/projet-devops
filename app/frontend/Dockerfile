# Aucune etape de build : des fichiers statiques servis par Nginx.
# C'est ce qui se deploie le plus simplement au monde, et l'image pese ~50 Mo.
FROM nginx:1.27-alpine

COPY index.html app.js style.css /usr/share/nginx/html/

# L'image officielle Nginx substitue les variables d'environnement dans tout
# fichier place ici, au demarrage du conteneur, et ecrit le resultat dans
# /etc/nginx/conf.d/. D'ou la portabilite : rien n'est fige dans l'image.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

ENV BACKEND_URL=http://backend:8000
# Garde-fou : ne substituer QUE cette variable dans le template. Sans ce filtre,
# l'entrypoint remplacerait aussi les variables propres a Nginx ($host, $uri...)
# si une variable d'environnement portait le meme nom.
ENV NGINX_ENVSUBST_FILTER="BACKEND_URL"

EXPOSE 80
