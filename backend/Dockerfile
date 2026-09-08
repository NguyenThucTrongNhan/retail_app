FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY . .

# Ensure the uploads directory exists for product image static serving (C4)
RUN mkdir -p /app/uploads

EXPOSE 8080
CMD ["npm", "start"]
