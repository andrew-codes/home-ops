FROM node:22.14.0-alpine

WORKDIR /app

ENV NODE_ENV production

COPY dist dist
RUN mv dist/package.json package.json

ENTRYPOINT [ "node", "dist/index.js" ]
