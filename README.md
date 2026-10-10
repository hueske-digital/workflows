# workflows

The reusable workflows of hueske-digital. A repository calls them by their
major version, which moves with every release of it:

```yaml
jobs:
  image:
    uses: hueske-digital/workflows/.github/workflows/image.yml@v1
    permissions:
      contents: read
      packages: write

  deploy:
    if: github.ref == 'refs/heads/main' && vars.DEPLOY_HOST != ''
    needs: image
    uses: hueske-digital/workflows/.github/workflows/deploy.yml@v1
    with:
      host: ${{ vars.DEPLOY_HOST }}
      stack: kunde
    secrets:
      secret: ${{ secrets.DEPLOY_SECRET }}
```

They run on the organization's runners (`[self-hosted, buildah]`), which
serve private repositories only: a public repository passes `runner:
github` to each, for GitHub's. Actions of others are named by their major
version in here. A caller sets its own `concurrency`, so that of two
pushes in a row the later one is the last to write `latest`.

## image.yml

Builds the repository's `Dockerfile` with Buildah and pushes it to
`ghcr.io/<owner>/<repository>` as `sha-<commit>`, as `latest` on the
default branch and under the tag's name for a pushed tag. Each
architecture is built on a runner of its own; two are joined into one
image by a second job, one is pushed with its tags by the build itself.
The layers are cached in the repository `<image>/cache` of the registry.

With a `schedule` of the caller the image follows its base images, once
a week by default:

```yaml
on:
  push:
    branches: [main]
  schedule:
    - cron: '0 4 * * 1'
```

A scheduled run builds when an image of the Dockerfile's `FROM` lines
changed since the last build (their digests are kept in a label of the
image) or `latest` is `stale-days` old, 30 by default, for the packages a
Dockerfile installs: the weekly run follows a base image within a week
and builds once a month otherwise. Every other run builds.

There is no Docker daemon: a Dockerfile builds as Buildah builds it, 1.33
on the organization's runners. `COPY --link`, `--parents` and `--exclude`
are refused there, `BUILDPLATFORM` is empty, a `# syntax=` line is
ignored, and there are no build secrets and no attestations. The image
is written in the docker format, which keeps `HEALTHCHECK` and `SHELL`.

With `cache: registry` every instruction is a layer of its own, kept in
the repository `<image>/cache`: every build reads it, and only builds of
the default branch and of tags write it, as a step in it is used by every
later build. That pays for a `RUN` that takes long. It has a price for
every instruction, though: Buildah compares the whole file tree to make
the layer and pulls or pushes a cache image of its own, 2 to 5 s each also
for a line that only configures, and tens of seconds once many files are
in the image. `cache: none` builds one layer a stage and asks no
registry: for a Dockerfile whose stages copy and configure it is the
faster one (one application's image took 155 s with the registry and
72 s without, a site's 17 s and 11 s). `astro.yml` builds without by
default (`layer-cache`). A pull
request passes `push: false` and builds only. Nothing is removed from the
registry: the tags `sha-<commit>-<arch>` of two architectures and the
cache's steps stay.

| Input | Default | |
|---|---|---|
| `image` | `ghcr.io/<owner>/<repository>` | the image without a tag |
| `archs` | `["amd64", "arm64"]` | a JSON list of `amd64` and `arm64` |
| `context` | `.` | the build context |
| `file` | `<context>/Dockerfile` | the Dockerfile, from the repository's root, else from the context |
| `build-args` | | one `NAME=value` a line |
| `labels` | | one `name=value` a line |
| `tags` | | tags besides `sha-<commit>`, one a line, instead of the defaults |
| `prepare` | | commands the runner runs before the image is built, a script of bash |
| `node-directory` | `.` | with `prepare`, the directory of `package.json` and the lockfile |
| `node-version-file` | `.nvmrc` | with `prepare`, names the Node version, in that directory |
| `build-contexts` | | one `name=directory` a line: the directory takes the place of the Dockerfile's stage of that name |
| `pnpm-store` | | with `prepare`, a path in the build where every `RUN` finds the runner's pnpm store |
| `cache` | `registry` | `none` builds one layer a stage and asks no registry |
| `latest` | `branch` | `release` puts `latest` on the newest pushed version tag and gives the default branch its own name as its tag |
| `push` | `true` | `false` builds only, as for a pull request |
| `stale-days` | `30` | a scheduled run builds a `latest` of that age; `0` builds every run |
| `runner` | `self-hosted` | `github` for a public repository |

Secret: `build-secrets`, the build's secrets, `ID=value` a line.

Outputs: `image`, `digest` of what was pushed, `version`, and `built`,
`false` for a scheduled run that found nothing to build.

A pushed version tag (`v1.2.3` or `1.2.3`) is a release: its image is
tagged `1.2.3` and `1.2`, and `latest` too with `latest: release`. Any
other tag is the image's tag as it is. `{version}` in a line of
`build-args` or `labels` is the release's version without the `v`, else
the tag, `pr-<number>` or the branch.

```yaml
    with:
      latest: release
      build-args: APP_VERSION=app@{version}
      # A release may build on GitHub's runners, everything else on the organization's.
      runner: ${{ startsWith(github.ref, 'refs/tags/') && 'github' || 'self-hosted' }}
    secrets:
      # Only a release gets the token: one without a value is not given to the build.
      build-secrets: |
        SENTRY_AUTH_TOKEN=${{ startsWith(github.ref, 'refs/tags/') && secrets.SENTRY_AUTH_TOKEN || '' }}
```

With `prepare` an application is built once, on the runner, where pnpm's
store and other caches survive between runs: the runner gets Node and
pnpm as the project names them and runs the commands, with `VERSION` and
the build secrets in their environment. `build-contexts` then puts what
they left in the place of stages of the Dockerfile, which are not built,
and the Dockerfile still builds alone. What must be made for the image's
own system (dependencies with native code) stays in a stage of the
Dockerfile; with `pnpm-store` its install finds the runner's store and
downloads only what that lacks.

```yaml
    with:
      prepare: |
        pnpm install --frozen-lockfile
        pnpm build
        scripts/assemble.sh stage/out
      build-contexts: build=stage
      pnpm-store: /pnpm/store
```

A build secret is in no layer and in no cache. The Dockerfile reads it
from a file in the one `RUN` that needs it, and that form builds with
Docker as well:

```dockerfile
RUN --mount=type=secret,id=SENTRY_AUTH_TOKEN \
  SENTRY_AUTH_TOKEN="$(cat /run/secrets/SENTRY_AUTH_TOKEN 2> /dev/null || true)" pnpm build
```

Buildah does not know BuildKit's `env=` of a secret mount
(`--mount=type=secret,id=…,env=…`): a Dockerfile with it fails at that
`RUN`, also without a secret (Buildah 1.33 and 1.43).

## astro.yml

Checks an Astro site, builds it on the runner and packs it into its image,
in one job: the scripts of `checks`, `astro build` with Astro's cache of
converted images and fonts kept between runs, the scripts of
`checks-after`, then the image as `image.yml` builds it, for one
architecture. The site's Dockerfile builds alone as well (`docker build
.`): it has a stage that builds the site, and the workflow puts the
`dist/` of the runner in that stage's place, so that the stage is not run
and the site is built once.

The workflow asks two things of the Dockerfile: a stage named `build`
(the input `stage`) that leaves the site in `/app/dist` (`stage-path`).
Everything else is the site's. Two forms of it are in use.

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

What both rely on, and why:

- **Few instructions in the stages the runner builds, and what changes
  with every build last.** On the organization's runners an instruction
  costs 4 to 5 s also when it comes from the cache (Buildah's vfs storage
  copies the image for each). The bundled form runs 7 of them in CI, the
  other about twice as many: its `base` and `deps` stages are built there
  too. For one site (weserkoeter) the image took 113 s with 17
  instructions and an install of its own in the runtime stage, and 51 s
  bundled; the image is 216 MB instead of 465 MB.
- **A package that cannot be bundled fails when the image starts**, not at
  the build. After adding a dependency of the server, a site of the
  bundled form runs its image once and uses what needs it (submits a
  form).
- **Node is PID 1 and ignores SIGTERM without a handler**: a stop waited
  30 s and ended in a kill (exit 137). The handler on the command line
  ends it at once with 0, without an init in the image; tini or the
  engine's init end it as fast, with 143, which systemd takes for a
  failed end.
- **No `HEALTHCHECK`.** The host's unit has the check
  (hueske-digital/infrastructure, `health:` of the stack's entry) and runs
  it with the image's `wget`; one in the image only serves a `docker run`
  by hand.
- **The site tells its commit and whether it is configured** at the page
  `deploy.yml` waits for (`health-json`), so that a site that is up but
  cannot do its job fails its deploy.

```yaml
jobs:
  site:
    uses: hueske-digital/workflows/.github/workflows/astro.yml@v1
    permissions:
      contents: read
      packages: write
    with:
      push: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request' }}
```

A scheduled run builds when a base image changed or `latest` is
`stale-days` old, as for `image.yml`, and skips the checks and the site's
build otherwise.

| Input | Default | |
|---|---|---|
| `directory` | `.` | the site's directory in the repository |
| `image` | `ghcr.io/<owner>/<repository>` | the image without a tag |
| `arch` | `arm64` | `amd64` or `arm64`, the host's |
| `node-version-file` | `.nvmrc` | names the Node version |
| `checks` | `lint check test` | scripts of `package.json` before the build |
| `checks-after` | | scripts after the build, which read `dist/` |
| `cache` | `.astro-cache` | Astro's `cacheDir` |
| `stage` | `build` | the Dockerfile's stage that builds the site |
| `stage-path` | `/app/dist` | where that stage leaves `dist/` |
| `layer-cache` | `none` | `registry` for a Dockerfile with a `RUN` that takes long |
| `file`, `build-args`, `labels`, `tags`, `push`, `stale-days`, `runner` | | as for `image.yml` |

Outputs: `image`, `digest` and `built`.

## node.yml

Checks a Node project with pnpm: Node as `.nvmrc` names it, pnpm as
`packageManager` of `package.json` does, `pnpm install --frozen-lockfile`
with pnpm's store kept between runs, then the commands of `run`. Every
run restores the store (a changed lockfile starts from the newest one
before it); only the default branch saves it, so that a pull request
uploads nothing. On the
organization's runners it takes one of either architecture. They have no
Docker daemon: tests that start containers pass `runner: github`.

```yaml
jobs:
  check:
    uses: hueske-digital/workflows/.github/workflows/node.yml@v1
    permissions:
      contents: read
```

| Input | Default | |
|---|---|---|
| `directory` | `.` | the project's directory in the repository |
| `node-version-file` | `.nvmrc` | names the Node version |
| `run` | `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build` | the commands after the install, a script of bash |
| `runner` | `self-hosted` | `github` for a public repository |
| `timeout` | `20` | minutes before the job is stopped |

## deploy.yml

Asks a host of hueske-digital/infrastructure to deploy a stack's new image
and, with `health-url`, waits until the stack's page tells the new version
([deploy/README.md](deploy/README.md)).

| Input | Default | |
|---|---|---|
| `host` | | the wan name of the stack's host, from a repository variable |
| `stack` | | the stack's name in the host's list |
| `health-url` | | a page of the stack that tells its version |
| `health-json` | | the fields it must answer with; `"{commit}"` is the run's commit |
| `health-timeout` | `600` | seconds before the job fails, 1500 at most |
| `runner` | `self-hosted` | `github` for a public repository |

Secret: `secret`, the stack's deploy secret. Deploys of one stack run one
after another. Only a `health-json` with `"{commit}"` shows that the new
version runs.
