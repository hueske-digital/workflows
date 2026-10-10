# astro.yml

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
The two forms a site's Dockerfile takes, and why, are in
[dockerfile.md](dockerfile.md).

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
