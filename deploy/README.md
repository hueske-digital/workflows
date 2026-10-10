# deploy

Asks a host of [hueske-digital/infrastructure](https://github.com/hueske-digital/infrastructure)
to deploy a stack's new image: a POST to the stack's deploy hook
`https://<host>/hooks/deploy-<stack>`, signed like GitHub's webhooks
(HMAC-SHA256 of the body with the stack's secret, header
`X-Hub-Signature-256`). A repository calls it as the workflow `deploy.yml`
(../README.md), which needs no runner of the caller; the action itself is
a step of a job:

```yaml
      - uses: hueske-digital/workflows/deploy@v1
        with:
          host: ${{ vars.DEPLOY_HOST }}   # the wan name of the stack's host
          stack: kunde                    # the stack's name in the host's list
          secret: ${{ secrets.DEPLOY_SECRET }}
```

In the repository's settings: the variable `DEPLOY_HOST` with the wan name
of the stack's host (like `wan.worksforme.wontfix.xyz`), and the secret
`DEPLOY_SECRET` with the stack's deploy secret from the host's secrets. A
stack that moves to another host changes only `DEPLOY_HOST`.

The step succeeds once the hook took the call (202); the deploy runs on the
host afterwards and reports to the monitoring as `<stack> deploy`. With
`health-url` the step waits for the new version instead: it asks the page
every 5 s until it answers 200 with the fields of `health-json`, and fails
after `health-timeout` seconds (600) with the last answer. A deploy takes a
few minutes, as the host pulls the image and waits for its health check.

```yaml
        with:
          host: ${{ vars.DEPLOY_HOST }}
          stack: kunde
          secret: ${{ secrets.DEPLOY_SECRET }}
          health-url: https://kunde.de/api/health
          health-json: '{"status": "ok", "commit": "{commit}"}'
```

`health-json` is a JSON object; the answer must hold each of its fields
with that value, and may hold more (`builtAt`, `uptimeSeconds`). The value
`"{commit}"` stands for the commit of the run: it matches its first 7
characters or more, as a site that tells the commit it was built from
writes it. Without `health-json`, or with one that names no `"{commit}"`,
the page only has to answer, which the version that runs now does as
well: the step warns that it shows nothing about the new one. `{commit}`
is the commit of the run that calls the action. A redirect is not
followed (a page behind a login answers with one), and `health-timeout`
is 1500 at most.
`health-url` is https, plain http only to this machine, as for `host`; a
mistake in these inputs fails the step before the hook is called.

Without `health-url` the step fails on any other answer of the hook than
202, with the reason:

| Answer | Meaning |
|---|---|
| 403 | the call was not signed |
| 404 | the host has no deploy hook for the stack: no `deploy: true` in its entry there, or another host |
| 500 | the signature does not match: another secret than the stack's |
| no answer, 502 to 504 | tried three times, 15 s each |

`host` is a host name, with a port if needed, without `https://` or a path;
`stack` is lower case letters, digits and `-`. The call goes over https;
plain http only to `localhost`, `127.0.0.1` and `[::1]`, for tests. The body
holds the repository, commit and run for the webhook's log; the host reads
none of it.

`test/run.sh` runs the action against the pinned adnanh/webhook image with
the hook as the infrastructure repository writes it, and against a local
page for `health-url` (docker and node).

A call whose answer was lost is sent again, up to three times; the host
then deploys a second time. The signature covers no time: a signed call
that was read can be sent again, which the host answers with another
deploy of the same image (hueske-digital/infrastructure,
docs/decisions/0037).
