# What a Dockerfile needs

The workflows build any Dockerfile. Whether it builds at all on the
organization's runners, and whether it builds in seconds or in minutes,
depends on a few things, all measured there.

## To build at all

The runners build with Buildah (1.33; GitHub's runners have a newer one),
not Docker.

- **Images by their full name**: `docker.io/library/nginx:alpine`, not
  `nginx:alpine`. Buildah on the runners refuses a short name ("did not
  resolve to an alias").
- **A build secret is read from its file**, in the one `RUN` that needs
  it. Buildah does not know BuildKit's `env=` of a secret mount
  (`--mount=type=secret,id=…,env=…`): a Dockerfile with it fails at that
  `RUN`, also without a secret (1.33 and 1.43). This form builds with
  Buildah and Docker, and without a secret the variable is empty:

  ```dockerfile
  RUN --mount=type=secret,id=SENTRY_AUTH_TOKEN \
    export SENTRY_AUTH_TOKEN="$(cat /run/secrets/SENTRY_AUTH_TOKEN 2> /dev/null || true)" \
    && pnpm build
  ```

- **No `COPY --link`, `--parents` or `--exclude`**, and no
  `FROM --platform=$BUILDPLATFORM`: Buildah 1.33 refuses the first three,
  and no Buildah sets `BUILDPLATFORM`. Each architecture is built on a
  runner of its own, so nothing has to be cross-compiled.
- **`ARG A="" B="x"` in one line, `COPY --chown` and `--chmod`** work.
  A `# syntax=` line is ignored. There are no attestations.
- The image is written in the docker format, which keeps `HEALTHCHECK`
  and `SHELL`; Buildah's default format drops both.

## To build fast

What costs time on the runners is not what one expects from Docker.

- **Build the application on the runner, not in the image.** There pnpm's
  store and the tools' own caches survive between runs; in the image
  every run starts from nothing. The Dockerfile keeps a stage that builds
  it, so that `docker build .` works alone, and the workflow puts what the
  runner built in that stage's place (`astro.yml` does it for a site,
  `prepare` and `build-contexts` of `image.yml` for anything else). One
  application's install and build took 150 s in the image and 20 s on the
  runner.
- **Make in the image only what belongs to its system**: dependencies with
  native code. Their install finds the runner's store with `pnpm-store`
  and downloads nothing.
- **No layer cache where stages copy and configure** (`cache: none`, the
  default of `astro.yml`). With a layer for every instruction Buildah
  compares the whole file tree to make each layer and pulls or pushes a
  cache image of its own: 2 to 5 s for a line that only configures, tens
  of seconds once many files are in the image. Without it a stage is one
  layer. The registry cache (`cache: registry`) pays only for a `RUN` that
  takes long and cannot move to the runner.
- **With the registry cache: few instructions, and what changes with
  every build last.** Every instruction after a changed one is built and
  written again. Fixed lines (`ENV`, `USER`, `EXPOSE`, `CMD`) stand before
  the copies, several `COPY --from` become one of a directory the build
  stage prepared, several `ARG` one line.
- **No `chown -R` over what was copied**: it stores the files a second
  time (one image went from 1.1 GB to 627 MB). `COPY --chown` instead.
- **A push from the home server is slow**: its uplink is 5 MB/s, the
  datacenter host's 36. What is uploaded there (image layers, a cache)
  shows in the run's time.

## To run on the hosts

- **Not root**: `USER node`, or the image's own user.
- **Ends on SIGTERM.** Node as PID 1 ignores it without a handler: a stop
  waited 30 s and ended in a kill (exit 137). A handler on the command
  line ends it at once with 0, without an init in the image; tini or the
  engine's init end it as fast, with 143, which systemd takes for a failed
  end.
- **Tells its commit**, and whether it is configured where it needs
  settings to do its job, at the page `deploy.yml` waits for
  (`/api/health`): a site that is up but old, or up but unable to send a
  form, then fails its deploy.
- **No `HEALTHCHECK` and no tini for an image the organization's hosts
  run**: the host's unit has the check (hueske-digital/infrastructure,
  `health:` of the stack's entry) and runs it with the image's `wget`. An
  image that runs elsewhere (mittwald) keeps both.
- **Port 4321** for a site, as the stacks' entries expect.

## An Astro site

The workflow asks two things of the Dockerfile: a stage named `build`
(the input `stage`) that leaves the site in `/app/dist` (`stage-path`).
Two forms are in use.

**Bundled**, the default for a site: `vite: { ssr: { noExternal: true } }`
in `astro.config.ts` puts the dependencies of the server's endpoints into
`dist/server`, and the image is Node and `dist/`.

```dockerfile
FROM node:26-alpine AS build
RUN npm install -g corepack@latest && corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN corepack install && pnpm install --frozen-lockfile
COPY . .
RUN pnpm build

FROM node:26-alpine AS runtime
ENV NODE_ENV=production HOST=0.0.0.0 PORT=4321 ASTRO_NODE_LOGGING=disabled
WORKDIR /app
USER node
EXPOSE 4321
CMD ["node", "--import", "data:text/javascript,process.on('SIGTERM',()=>process.exit(0))", "./dist/server/entry.mjs"]

COPY --from=build /app/dist ./dist
```

**With `node_modules`**, as Astro's Docker recipe has it, for a site whose
server needs a package that cannot be bundled (native code, like `sharp`
for images on request or a database driver): no line in `astro.config.ts`,
and the runtime stage takes the production dependencies from a stage of
their own.

```dockerfile
FROM node:26-alpine AS base
RUN npm install -g corepack@latest && corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN corepack install

FROM base AS build
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm build

FROM base AS deps
RUN pnpm install --prod --frozen-lockfile

FROM node:26-alpine AS runtime
ENV NODE_ENV=production HOST=0.0.0.0 PORT=4321 ASTRO_NODE_LOGGING=disabled
WORKDIR /app
USER node
EXPOSE 4321
CMD ["node", "--import", "data:text/javascript,process.on('SIGTERM',()=>process.exit(0))", "./dist/server/entry.mjs"]

COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
```

A site whose every page is prerendered needs nothing at request time but
Node: images are converted at the build, and what depends on the time of
the request is a server island or a few lines of script. A site that
renders on request with `output: "server"` needs sharp there, which
cannot be bundled.

## An application with dependencies of its own system

Where the image needs `node_modules` (a database driver with native
code), three stages: one that builds, which the runner replaces; one that
installs the production dependencies for the image's system; the runtime.

```dockerfile
FROM docker.io/library/node:26-alpine AS deps
ENV PNPM_HOME=/pnpm PATH=/pnpm:$PATH
RUN npm install -g pnpm@12
WORKDIR /app
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY apps/api/package.json apps/api/

# Everything `docker build .` needs; the runner's result takes its place in CI.
FROM deps AS build
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile
COPY . .
RUN pnpm build && scripts/assemble.sh /out

# For the image's system; finds the runner's store at /pnpm/store in CI.
FROM deps AS prod
RUN pnpm deploy --filter api --prod /deploy/api

FROM docker.io/library/node:26-alpine AS runtime
ENV NODE_ENV=production PORT=3000
USER node
WORKDIR /app
EXPOSE 3000
CMD ["node", "dist/server.js"]
COPY --from=prod --chown=node:node /deploy/api/node_modules /app/node_modules
COPY --from=build --chown=node:node /out/ /app/
```

A script of the repository (`scripts/assemble.sh` here) puts together
what the image needs from the built tree, for the Dockerfile's stage and
for the runner alike, so that both leave the same.
