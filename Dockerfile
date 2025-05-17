FROM node:20-slim

# Install required packages: curl, jq, zenity, bash
RUN apt-get update && \
    apt-get install -y curl jq zenity bash at-spi2-core  && \
    apt-get clean

WORKDIR /app

COPY package*.json ./

RUN npm install 

COPY . .


RUN chmod +x ./api_tester.sh

EXPOSE 3000

CMD ["node", "server.js"]
