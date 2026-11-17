# ─────────────────────────────────────────────
# Stage 1 — build
# Compile le frontend Vite et produit le dossier dist/
# ─────────────────────────────────────────────
FROM node:20-alpine AS build

WORKDIR /app

# Copie des manifestes en premier pour profiter du cache de couches
COPY package.json package-lock.json ./

# --ignore-scripts : empêche l'exécution de scripts postinstall arbitraires
RUN npm ci --ignore-scripts

# Copie des sources frontend uniquement (pas le backend ni les docs)
COPY index.html gestion-quiz.html vite.config.js ./
COPY main.js style.css javascript.svg ./
COPY public/ ./public/
COPY images/ ./images/
COPY questions_docker.js \
     questions_devops.js \
     questions_cicd.js \
     questions_ansible.js \
     questions_scm.js \
     questions_usine-logicielle.js \
     questions_defaut_0.js \
     questions_defaut_1.js \
     ./

RUN npm run build


# ─────────────────────────────────────────────
# Stage 2 — prod
# Sert les fichiers statiques via Nginx Alpine
#
# Ports (doc 08-documentation-technique) :
#   - Nginx écoute sur le port 80 DANS le conteneur
#   - Le mapping vers l'hôte (ex. 8087:80) est défini dans docker-compose.yml
#
# Sécurité :
#   nginx:alpine inclut l'utilisateur "nginx" (uid 101).
#   Le processus master nginx s'exécute en root uniquement le temps de binder
#   le port 80, puis délègue immédiatement aux workers qui tournent sous "nginx".
#   Les fichiers et répertoires sont owned par "nginx" pour limiter la surface.
# ─────────────────────────────────────────────
FROM nginx:alpine AS prod

# Copie de la configuration Nginx personnalisée
COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf

# Copie du build Vite
COPY --from=build /app/dist /usr/share/nginx/html

# Attribution des droits sur les ressources Nginx aux workers non-root
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

# Port 80 dans le conteneur — mapping hôte défini dans docker-compose.yml
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
