FROM node:22-alpine

WORKDIR /app

# Copy the manifest first so the dependency layer is cached separately
COPY package*.json ./
RUN npm install --omit=dev

COPY app.js ./

EXPOSE 3000
CMD ["npm", "start"]
