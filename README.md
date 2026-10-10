# workflows

Reusable workflows of hueske-digital. A caller pins the commit of a release:

```yaml
jobs:
  image:
    uses: hueske-digital/workflows/.github/workflows/image.yml@<commit> # v1
    permissions:
      contents: read
      packages: write
```

## image.yml

Builds the repository's `Dockerfile` with Buildah and pushes it to
`ghcr.io/<owner>/<repository>` as `sha-<commit>`, as `latest` on the
default branch and under the tag's name for a pushed tag. Each
architecture is built on a runner of its own; two are joined into one
image by a second job, one is pushed with its tags by the build itself.
The layers are cached in the repository `<image>/cache` of the registry.

A private repository builds on the organization's runners (`[self-hosted,
buildah]`), a public one on GitHub's: `runner` overrides it. There is no
Docker daemon: a Dockerfile builds as Buildah builds it.

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
