# node.yml

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
