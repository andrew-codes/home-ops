FROM node:22.14.0-alpine

WORKDIR /app

ENV NODE_ENV production

COPY dist dist

ENTRYPOINT [ "node", "dist/index.js" ]
