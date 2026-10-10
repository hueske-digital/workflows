# image.yml

Builds a repository's `Dockerfile` with Buildah and pushes it to
`ghcr.io/<owner>/<repository>`. Each architecture is built on a runner of
its own; two are joined into one image by a second job, one is pushed with
its tags by the build itself. What the Dockerfile has to look like is in
[dockerfile.md](dockerfile.md).

```yaml
jobs:
  image:
    uses: hueske-digital/workflows/.github/workflows/image.yml@v1
    permissions:
      contents: read
      packages: write
```

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

## Tags

Every image is tagged `sha-<commit>`. The default branch's is `latest`
too. A pushed version tag (`v1.2.3` or `1.2.3`) is a release: its image is
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

## Following the base images

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

The comparison reads the tag the default branch builds: `latest`, or the
branch's name with `latest: release`. A Dockerfile whose `FROM` names a
variable, or a caller with its own `tags`, is built by every scheduled
run.

## Building on the runner first

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

## The layer cache

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
default (`layer-cache`).

Nothing is removed from the registry: the tags `sha-<commit>-<arch>` of
two architectures and the cache's steps stay.

## Build secrets

A build secret is a file for the one `RUN` of the Dockerfile that mounts
it, in no layer and in no cache; [dockerfile.md](dockerfile.md) has the
form that builds with Buildah and Docker alike. One without a value is not
given, so that a caller gives a token to its releases only. With `prepare`
the secrets are in the environment of its commands as well.
