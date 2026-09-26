# GOV.UK App Preview

A lightweight orchestrator for running disposable, branch-specific preview instances of GOV.UK applications. It checks out a requested branch, builds the application's own Dockerfile, allocates it a port, and runs it — so, for example, several branches of Whitehall (each with its own dependencies) can be previewed simultaneously without reproducing the full GOV.UK development or production Kubernetes architecture.

This app owns its own local development setup (below) rather than depending on [govuk-docker](https://github.com/alphagov/govuk-docker).

## Local development

Prerequisite: Docker Desktop, and `*.dev.gov.uk` resolving to `127.0.0.1` locally - the standard GOV.UK dev machine setup. If `dig frontend-main.govuk-app-preview.dev.gov.uk` doesn't return `127.0.0.1`, add a wildcard rule for the whole domain to your dnsmasq config (e.g. `/opt/homebrew/etc/dnsmasq.d/`):

```
address=/dev.gov.uk/127.0.0.1
```

Then:

```
docker compose up --build
```

This builds and starts Postgres, Redis, the app, a Sidekiq worker, and a small nginx reverse proxy fronting all of it at `*.govuk-app-preview.dev.gov.uk` - mirroring the wildcard-subdomain routing App Preview uses on integration (see `HostRouter`). The database is prepared and seeded automatically; no separate setup step is needed on a fresh checkout.

Visit <http://govuk-app-preview.dev.gov.uk/previews>.

Once a preview reaches "running", it's reachable directly at its own hostname, e.g. `http://frontend-my-branch.govuk-app-preview.dev.gov.uk/`.

**Known conflict**: the local nginx proxy binds host port 80 by default, same as govuk-docker's own `nginx-proxy` - the two can't both be `up` at once. Set `APP_PREVIEW_NGINX_PORT` to use a different port if you need both running simultaneously.
