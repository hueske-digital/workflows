# workflows

The reusable workflows of hueske-digital: what a repository's CI calls
instead of carrying its own steps.

| Workflow | What it does | |
|---|---|---|
| `image.yml` | builds an image with Buildah and pushes it to ghcr.io | [docs/image.md](docs/image.md) |
| `astro.yml` | checks an Astro site, builds it and packs it into its image | [docs/astro.md](docs/astro.md) |
| `node.yml` | checks a Node project with pnpm | [docs/node.md](docs/node.md) |
| `deploy.yml` | asks a host to deploy a stack's new image and waits for it | [docs/deploy.md](docs/deploy.md) |

What a Dockerfile needs to build with them, and to build fast, is in
[docs/dockerfile.md](docs/dockerfile.md).

## Calling them

A repository calls a workflow by its major version, which moves with
every release of it; a site's whole CI is two jobs:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '0 4 * * 1'

permissions: {}

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  site:
    uses: hueske-digital/workflows/.github/workflows/astro.yml@v1
    permissions:
      contents: read
      packages: write
    with:
      push: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request' }}

  deploy:
    needs: site
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request' && needs.site.outputs.built == 'true'
    uses: hueske-digital/workflows/.github/workflows/deploy.yml@v1
    with:
      host: ${{ vars.DEPLOY_HOST }}
      stack: kunde
      health-url: https://kunde.de/api/health
      health-json: '{"status": "ok", "commit": "{commit}"}'
    secrets:
      secret: ${{ secrets.DEPLOY_SECRET }}
```

- **Runners.** The workflows run on the organization's own runners
  (`[self-hosted, buildah]`: one job a container, Buildah and no Docker
  daemon), which serve private repositories only. A public repository
  passes `runner: github` to each call, for GitHub's.
- **Permissions.** The caller grants them per job: `contents: read`,
  `packages: write` where an image is pushed, and `packages: read` where
  `node.yml` installs from GitHub's npm registry. A called workflow cannot
  take more.
- **Concurrency** is the caller's, so that of two pushes in a row the
  later one is the last to write `latest`.
- **A schedule** makes an image follow its base images: a scheduled run
  builds only when an image of the Dockerfile's `FROM` lines changed or
  the last build is `stale-days` old ([docs/image.md](docs/image.md)).

## In this repository

| Path | |
|---|---|
| `.github/workflows/` | the four workflows, and `test.yml`, which runs them |
| `scripts/build.sh` | the image build of `image.yml` and `astro.yml`; they fetch it at the commit they are called at |
| `deploy/` | the action `deploy.yml` runs, with its test against a real webhook |
| `test/` | what `test.yml` builds: an image, a site, a prepared build, a project with a package from GitHub's npm registry, and `test/build.sh`, the cases of `scripts/build.sh` |
| `docs/` | one page a workflow, and the Dockerfile's |

Actions of others are named by their major version in here.

## Changing and releasing

A change is pushed to `main`, where `test.yml` runs every workflow on
GitHub's runners (this repository is public, and the organization's
runners serve private ones only) together with shellcheck, actionlint,
`test/build.sh` and the deploy action's test. What only shows on the
organization's runners (their older Buildah, their network) is tried from
a branch of a private repository that calls the workflow by its commit
instead of `v1`.

A release is a tag `v1.x.y` on a commit whose test was green, and `v1`
moved to it: every caller has it with its next run.

```sh
git tag v1.x.y && git tag -f v1 && git push origin v1.x.y && git push -f origin v1
```
