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
github` to each, for GitHub's. Actions of others are pinned by their
commit in here. A caller sets its own `concurrency`, so that of two
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
image) or `latest` is `stale-days` old, for the packages a Dockerfile
installs: a week old, so the weekly run builds unless a push built the
image in between and its base is the same. A daily `schedule` follows a
base image within a day and still builds at most once a week otherwise.
Every other run builds.

There is no Docker daemon: a Dockerfile builds as Buildah builds it, 1.33
on the organization's runners. `COPY --link`, `--parents` and `--exclude`
are refused there, `BUILDPLATFORM` is empty, a `# syntax=` line is
ignored, and there are no build secrets and no attestations. The image
is written in the docker format, which keeps `HEALTHCHECK` and `SHELL`.

Every build reads the cache; only builds of the default branch and of
tags write it, as a step in it is used by every later build. A pull
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
| `push` | `true` | `false` builds only, as for a pull request |
| `stale-days` | `7` | a scheduled run builds a `latest` of that age; `0` builds every run |
| `runner` | `self-hosted` | `github` for a public repository |

Outputs: `image`, `digest` of what was pushed, and `built`, `false` for a
scheduled run that found nothing to build.

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
| `health-timeout` | `600` | seconds before the job fails |
| `runner` | `self-hosted` | `github` for a public repository |

Secret: `secret`, the stack's deploy secret.
