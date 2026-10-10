# deploy.yml

Asks a host of hueske-digital/infrastructure to deploy a stack's new image
and, with `health-url`, waits until the stack's page tells the new
version. It runs the action in [`deploy/`](../deploy/README.md), whose
page has the hook's answers and what the health check compares.

```yaml
jobs:
  deploy:
    needs: image
    if: github.ref == 'refs/heads/main' && needs.image.outputs.built == 'true'
    uses: hueske-digital/workflows/.github/workflows/deploy.yml@v1
    with:
      host: ${{ vars.DEPLOY_HOST }}
      stack: kunde
      health-url: https://kunde.de/api/health
      health-json: '{"status": "ok", "commit": "{commit}"}'
    secrets:
      secret: ${{ secrets.DEPLOY_SECRET }}
```

| Input | Default | |
|---|---|---|
| `host` | | the wan name of the stack's host, from a repository variable |
| `stack` | | the stack's name in the host's list |
| `health-url` | | a page of the stack that tells its version |
| `health-json` | | the fields it must answer with; `"{commit}"` is the run's commit |
| `health-timeout` | `600` | seconds before the job fails, 1500 at most |
| `runner` | `self-hosted` | `github` for a public repository |

Secret: `secret`, the stack's deploy secret.

In the repository's settings: the variable `DEPLOY_HOST` with the wan
name of the stack's host, and the secret `DEPLOY_SECRET` with the stack's
deploy secret from the host's secrets. Deploys of one stack run one after
another. Only a `health-json` with `"{commit}"` shows that the new version
runs: the version before it answers the page as well.
