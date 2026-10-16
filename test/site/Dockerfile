# Builds alone (docker build .), where the stage build runs the site's
# build; astro.yml puts the dist/ it built on the runner in that stage's
# place, and the stage is not run.
FROM docker.io/library/node:24-alpine AS build
WORKDIR /app
RUN npm install -g pnpm@11.17.0
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY scripts.mjs ./
RUN pnpm build

FROM docker.io/library/alpine:3.22
COPY --from=build /app/dist /site
CMD ["cat", "/site/index.html"]
