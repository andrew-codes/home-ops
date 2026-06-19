# The service is bundled to a single self-contained dist/server.js by the
# `compile` target (esbuild via @ha/build-ts) before this image is built, so the
# runtime image needs no npm/yarn install and no node_modules.
FROM node:22.14.0-slim

WORKDIR /app
COPY dist/ ./dist/

ENV VOICE_AGENT_HOST=0.0.0.0
ENV VOICE_AGENT_PORT=8000
EXPOSE 8000

CMD ["node", "dist/server.js"]
