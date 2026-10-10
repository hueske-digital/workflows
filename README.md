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

A private repository runs them on the organization's runners
(`[self-hosted, buildah]`), a public one on GitHub's; the input `runner`
(`self-hosted`, `github`, `auto`) overrides it. Actions of others are
pinned by their commit in here.

## image.yml

Builds the repository's `Dockerfile` with Buildah and pushes it to
`ghcr.io/<owner>/<repository>` as `sha-<commit>`, as `latest` on the
default branch and under the tag's name for a pushed tag. Each
architecture is built on a runner of its own; two are joined into one
image by a second job, one is pushed with its tags by the build itself.
The layers are cached in the repository `<image>/cache` of the registry.

There is no Docker daemon: a Dockerfile builds as Buildah builds it.

| Input | Default | |
|---|---|---|
| `image` | `ghcr.io/<owner>/<repository>` | the image without a tag |
| `archs` | `["amd64", "arm64"]` | a JSON list of `amd64` and `arm64` |
| `context` | `.` | the build context |
| `file` | `<context>/Dockerfile` | the Dockerfile, from the repository's root |
| `build-args` | | one `NAME=value` a line |
| `labels` | | one `name=value` a line |
| `tags` | | tags besides `sha-<commit>`, one a line, instead of the defaults |
| `push` | `true` | `false` builds only, as for a pull request |
| `runner` | `auto` | `self-hosted`, `github` or `auto` |

Outputs: `image`, and `digest` of what was pushed.

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
| `runner` | `auto` | `self-hosted`, `github` or `auto` |

Secret: `secret`, the stack's deploy secret.
