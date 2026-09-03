# ---- Stage 1: build the static bundle ----
FROM node:22-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm install

COPY . .
RUN npm run build

# ---- Stage 2: serve it ----
# Only the compiled dist/ is copied over, so node and node_modules
# never reach the final image.
FROM nginx:1.27-alpine

COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80
