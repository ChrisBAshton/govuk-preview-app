# GOV.UK Preview App

A lightweight orchestrator for running disposable, branch-specific preview instances of GOV.UK applications. It checks out a requested branch, builds the application's own Dockerfile, allocates it a port, and runs it — so, for example, several branches of Whitehall (each with its own dependencies) can be previewed simultaneously without reproducing the full GOV.UK development or production Kubernetes architecture.

This app owns its own local development setup (below) rather than depending on [govuk-docker](https://github.com/alphagov/govuk-docker).

## How it works

Preview App is a Rails app plus a Sidekiq worker, orchestrating Docker containers via a mounted host Docker socket ("Docker-outside-of-Docker"). Every preview's containers are siblings of Preview App's own containers on the same Docker daemon - not nested inside them - which is why restarting Preview App's own containers never disturbs a preview that's already running.

### The manifest

`config/govuk_apps.yml` (parsed by `lib/govuk_apps.rb`) lists every app Preview App knows how to build: its `repo_url`, `port_env_var`, an optional `database` (adapter + Docker image), optional `dependencies` (other manifest entries that must be running first), optional `setup_tasks` and `worker_command` (see steps 6-7 below), `publicly_readable` for a dependency that's safe to make hostname-routable (see Routing), an optional `env_aliases` hash (see step 1 below), and a fixed `env` hash for anything that app needs pointed at a real GOV.UK service or a quirk of its own that needs a specific env var.

### Building a preview

Creating a `Preview` (an app name + branch) enqueues `PreviewsCreateJob`, which delegates to `PreviewBuilder#build!`. This drives the preview through a sequence of statuses - `queued` → `checking_out` → `building` → `starting` → `running`, or `failed` at any step:

1. **Dependencies first.** For each app named in the manifest's `dependencies`, in order, build a fresh, dedicated `Preview` (always branch `main`, never shared across parents) recursively, and inject its `PLEK_SERVICE_<NAME>_URI` into the parent's env once it's running - the real, internal `container:port` address, only ever reachable by sibling containers over Docker's embedded DNS (fine for server-to-server use, e.g. Frontend's own Content Store lookups). If the dependency is `publicly_readable`, its real, browser-reachable URL is *also* injected as `PLEK_SERVICE_<NAME>_PUBLIC_URL` - needed for anything meant to end up as a clickable link rather than a server-to-server call (see `ConfigOverrides`' Whitehall override below). Order matters: each dependency also inherits everything resolved by every dependency built *before* it in the same list - e.g. Whitehall's `frontend` dependency, declared after `publishing-api`, ends up pointed at the real local Content Store that `publishing-api`'s own `content-store` dependency resolved, not frontend's own static, real-GOV.UK default. A manifest entry's own `env_aliases` can then re-expose one of those inherited addresses under a *different* env var key, for that preview's own container only (never propagated onward to further siblings) - needed when an app's code always reads a fixed env var name regardless of which physical instance it's actually talking to, e.g. `draft-frontend` is the exact same codebase as `frontend`, which only ever reads `PLEK_SERVICE_CONTENT_STORE_URI` (never `PLEK_SERVICE_DRAFT_CONTENT_STORE_URI`) - its `env_aliases` re-exposes whatever it inherited under the latter key as the former.
2. **Checkout** (`Checkout`) - a shallow git clone (or fetch, if already checked out) of the requested branch into `tmp/checkouts/<app>/<slug>`.
3. **Config overrides** (`ConfigOverrides`) - writes a fixed initializer into the checkout, unconditionally, fixing three classes of problem a plain env var can't reach: some apps hardcode an `x_sendfile_header` that assumes a filesystem-sharing reverse proxy (there isn't one here, so the app has to serve its own files); some apps' `database.yml` ignores `DATABASE_URL` under `RAILS_ENV=production`; some apps set `config.hosts` to a real GOV.UK-only allowlist, which would 403 every preview subdomain.
4. **Build** (`DockerRunner#build!`) - `docker build`s the app's own Dockerfile, tagged `govuk-preview-app/<app>:<slug>`.
5. **Database**, if the manifest declares one (`DatabaseRunner`) - starts a dedicated, disposable MySQL/Postgres container (never shared, no host-published port), then `DockerRunner#migrate!` creates the schema (`db:create db:schema:load` - deliberately not `db:seed` too, since `db:prepare` already seeds a freshly-created database itself) and `#seed!` runs `db:seed` as its own step.
6. **Setup tasks**, if the manifest declares any (`DockerRunner#run_setup_task!`) - runs each named `bin/rails` task, in order, as its own one-off container. For data only the previewed app's own rake tasks know how to create (e.g. Whitehall needs a basic taxonomy in Publishing API before a document can be tagged to a topic - the same task govuk-docker's own Makefile runs) - this keeps that knowledge in config, not hardcoded into Preview App itself.
7. **Start** (`DockerRunner#start!`) - runs the built image, publishing the preview's allocated port to the host *unless* this is a dependency preview. If the manifest declares a `worker_command`, a second, long-running container also starts from the same image running that command instead of the app's own web server (`DockerRunner#start_worker!`) - e.g. Publishing API's Sidekiq worker, which pushes published content downstream to Content Store; without it, nothing would ever leave Publishing API's own database.

Every container name and image tag is namespaced by the preview's `slug` (app + branch, parameterised) via `ContainerName`, which also truncates and hashes anything that would exceed the 63-character DNS label limit - container names double as hostnames for Docker's embedded resolver, and a long branch name can otherwise silently break cross-container networking.

### Routing

`HostRouter` (a Rack middleware) inspects every request's `Host` header: if it matches a `running`, non-dependency preview's hostname (`<slug>.<PREVIEW_APP_BASE_DOMAIN>`), it proxies straight to that preview's own container over the shared Docker network, never touching Preview App's own routes or auth. Anything else - Preview App's own UI, or an unmatched/stale subdomain - falls through as normal.

A dependency preview is normally internal-only - never hostname-routable, since most (e.g. Publishing API) are unauthenticated, state-mutating APIs. A manifest entry marked `publicly_readable: true` (e.g. Content Store) is the one exception: it's routable at a short, randomised hostname (`Preview#generate_public_hostname`), generated once per instance rather than derived from its place in the dependency tree - there's no value in the public URL expressing those relationships, and it'd otherwise be a long chain (e.g. `content-store-main-for-publishing-api-main-for-whitehall-my-branch`). Since a dependency is always dedicated to one parent and never shared, this hostname is unique to that specific instance - two Whitehall previews each get their own, entirely separate Content Store, never a single shared one that could end up with both posting to the same path. `draft-content-store`/`draft-frontend` are ordinary manifest entries with the same `publicly_readable: true` treatment as their live counterparts, so each also gets its own public, randomised hostname - useful for inspecting Whitehall's draft pipeline directly, not just via its own "Preview on website" link.

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
