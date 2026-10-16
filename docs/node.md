# node.yml

Checks a Node project with pnpm: Node as `.nvmrc` names it, pnpm as
`packageManager` of `package.json` does, `pnpm install --frozen-lockfile`
with pnpm's store kept between runs, then the commands of `run`. Every
run restores the store (a changed lockfile starts from the newest one
before it); only the default branch saves it, so that a pull request
uploads nothing. On the
organization's runners it takes one of either architecture. They have no
Docker daemon: tests that start containers pass `runner: github`.

A project with packages from GitHub's npm registry names the registry for
their scope in its `.npmrc` (`@hueske-digital:registry=https://npm.pkg.github.com`)
and passes `github-packages: true` with `packages: read`. The run's token
then fills pnpm's store with `pnpm fetch`, which runs no script of a
dependency, and is gone before the install that runs them.

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
| `github-packages` | `false` | `true` lets `pnpm install` read packages from GitHub's npm registry (`npm.pkg.github.com`) with the run's token; the caller grants `packages: read` |
| `run` | `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build` | the commands after the install, a script of bash |
| `runner` | `self-hosted` | `github` for a public repository |
| `timeout` | `20` | minutes before the job is stopped |
