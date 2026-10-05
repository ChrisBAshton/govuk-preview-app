# GOV.UK Preview App

A lightweight orchestrator for running disposable, branch-specific preview instances of GOV.UK applications. It checks out a requested branch, builds the application's own Dockerfile, allocates it a port, and runs it — so, for example, several branches of Whitehall (each with its own dependencies) can be previewed simultaneously without reproducing the full GOV.UK development or production Kubernetes architecture.

This app owns its own local development setup (below) rather than depending on [govuk-docker](https://github.com/alphagov/govuk-docker).

## How it works

Preview App is a Rails app plus a Sidekiq worker, orchestrating Docker containers via a mounted host Docker socket ("Docker-outside-of-Docker"). Every preview's containers are siblings of Preview App's own containers on the same Docker daemon - not nested inside them - which is why restarting Preview App's own containers never disturbs a preview that's already running.

### The manifest

`config/govuk_apps.yml` (parsed by `lib/govuk_apps.rb`) lists every app Preview App knows how to build: its `repo_url`, `port_env_var`, an optional `database` (adapter + Docker image), optional `dependencies` (other manifest entries that must be running first), and a fixed `env` hash for anything that app needs pointed at a real GOV.UK service (e.g. a read-only Content Store) or a quirk of its own that needs a specific env var.

### Building a preview

Creating a `Preview` (an app name + branch) enqueues `PreviewsCreateJob`, which delegates to `PreviewBuilder#build!`. This drives the preview through a sequence of statuses - `queued` → `checking_out` → `building` → `starting` → `running`, or `failed` at any step:

1. **Dependencies first.** For each app named in the manifest's `dependencies`, build a fresh, dedicated `Preview` (always branch `main`, never shared across parents) recursively, and inject its `PLEK_SERVICE_<NAME>_URI` into the parent's env once it's running.
2. **Checkout** (`Checkout`) - a shallow git clone (or fetch, if already checked out) of the requested branch into `tmp/checkouts/<app>/<slug>`.
3. **Config overrides** (`ConfigOverrides`) - writes a fixed initializer into the checkout, unconditionally, fixing three classes of problem a plain env var can't reach: some apps hardcode an `x_sendfile_header` that assumes a filesystem-sharing reverse proxy (there isn't one here, so the app has to serve its own files); some apps' `database.yml` ignores `DATABASE_URL` under `RAILS_ENV=production`; some apps set `config.hosts` to a real GOV.UK-only allowlist, which would 403 every preview subdomain.
4. **Build** (`DockerRunner#build!`) - `docker build`s the app's own Dockerfile, tagged `govuk-preview-app/<app>:<slug>`.
5. **Database**, if the manifest declares one (`DatabaseRunner`) - starts a dedicated, disposable MySQL/Postgres container (never shared, no host-published port), then `DockerRunner#migrate!` creates the schema (`db:create db:schema:load` - deliberately not `db:seed` too, since `db:prepare` already seeds a freshly-created database itself, and running seeds twice broke at least one real app's non-idempotent seed script). A separate `#seed!` step then runs `db:seed` on its own - if that fails, the preview still reaches `running`, with a warning message recorded, since a broken or unmaintained seed script shouldn't block previewing an app entirely.
6. **Start** (`DockerRunner#start!`) - runs the built image, publishing the preview's allocated port to the host *unless* this is a dependency preview. A dependency (e.g. Publishing API) is an unauthenticated, state-mutating API, so it's only ever reachable by its sibling containers via Docker's own embedded DNS - never published to the host or made hostname-routable.

Every container name and image tag is namespaced by the preview's `slug` (app + branch, parameterised) via `ContainerName`, which also truncates and hashes anything that would exceed the 63-character DNS label limit - container names double as hostnames for Docker's embedded resolver, and a long branch name can otherwise silently break cross-container networking.

### Routing

`HostRouter` (a Rack middleware) inspects every request's `Host` header: if it matches a `running`, non-dependency preview's hostname (`<slug>.<PREVIEW_APP_BASE_DOMAIN>`), it proxies straight to that preview's own container over the shared Docker network, never touching Preview App's own routes or auth. Anything else - Preview App's own UI, or an unmatched/stale subdomain - falls through as normal.

### Tearing down

Deleting a preview enqueues `PreviewsDestroyJob`, which delegates to `PreviewDestroyer#destroy!` - recursively destroying every dependent preview's own containers, database and checkout first, then the preview's own. This is deliberately not a plain `dependent: :destroy` association, which would only clean up database rows, not the real infrastructure they own.

### Staying honest about what's actually running

`PreviewReconciler` runs at boot (see `docker-compose.yml`'s `app`/`worker` commands) and marks any `running` preview `failed` if its actual container(s) no longer exist - for example if the underlying node or Docker daemon was ever replaced. Without this, a preview whose infrastructure disappeared out from under it would stay marked `running` forever, with `HostRouter` proxying to nothing.

## Local development

Prerequisite: Docker Desktop, and `*.dev.gov.uk` resolving to `127.0.0.1` locally - the standard GOV.UK dev machine setup. If `dig frontend-main.govuk-preview-app.dev.gov.uk` doesn't return `127.0.0.1`, add a wildcard rule for the whole domain to your dnsmasq config (e.g. `/opt/homebrew/etc/dnsmasq.d/`):

```
address=/dev.gov.uk/127.0.0.1
```

Then:

```
docker compose up --build
```

This builds and starts Postgres, Redis, the app, a Sidekiq worker, and a small nginx reverse proxy fronting all of it at `*.govuk-preview-app.dev.gov.uk` - mirroring the wildcard-subdomain routing Preview App uses on integration (see `HostRouter`). The database is prepared and seeded automatically; no separate setup step is needed on a fresh checkout.

Visit <http://govuk-preview-app.dev.gov.uk:8080/previews>.

Once a preview reaches "running", it's reachable directly at its own hostname, e.g. `http://frontend-my-branch.govuk-preview-app.dev.gov.uk:8080/`.

The local nginx proxy defaults to host port 8080, not 80 - govuk-docker's own `nginx-proxy` already binds port 80 on most GOV.UK dev machines, and only one process can hold a given host port at a time (this is an OS-level TCP binding constraint, not a hostname-routing one, so it'd happen regardless of which `*.dev.gov.uk` hostname either proxy is fronting). Set `PREVIEW_APP_NGINX_PORT` to use a different port if 8080 is also taken. This is purely a local-dev concern - a real Kubernetes deployment has no equivalent host-port conflict (each pod gets its own network namespace) and needs no corresponding config.
