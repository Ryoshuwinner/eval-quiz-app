# ─────────────────────────────────────────────
# Stage 1 — build
# Installe uniquement les dépendances de production
# ─────────────────────────────────────────────
FROM node:20-alpine AS build

WORKDIR /app

# Copie du manifeste en premier pour profiter du cache de couches.
# Note : package-lock.json n'est pas présent dans le dépôt initial ;
# npm install le génère. Une fois committé, remplacer npm install par npm ci
# pour des builds strictement reproductibles.
COPY package.json ./

# --omit=dev : exclut devDependencies
# --ignore-scripts : empêche l'exécution de scripts postinstall arbitraires
RUN npm install --omit=dev --ignore-scripts


# ─────────────────────────────────────────────
# Stage 2 — prod
# Image finale allégée, sans npm ni cache
# ─────────────────────────────────────────────
FROM node:20-alpine AS prod

# Création d'un utilisateur non-root sans shell de login ni répertoire home superflu
# UID/GID 1001 explicites pour être résolvables par le système hôte
RUN addgroup -g 1001 -S appgroup \
    && adduser -u 1001 -S -G appgroup -H -s /sbin/nologin appuser

WORKDIR /app

# Copie des dépendances installées depuis le stage build
COPY --from=build /app/node_modules ./node_modules

# Copie du code source du backend uniquement
COPY server.js package.json ./

# Attribution des droits à l'utilisateur non-root
RUN chown -R 1001:1001 /app

USER 1001

EXPOSE 3007

CMD ["node", "server.js"]
