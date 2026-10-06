# GOV.UK Preview App

A lightweight orchestrator for running disposable, branch-specific preview instances of GOV.UK applications on Kubernetes. Given an app and a branch, it runs the image that branch's own CI already built, alongside a dedicated copy of every service it depends on - so, for example, several branches of Whitehall (each with its own Publishing API, Content Stores, Frontends and databases) can be previewed side by side, each at its own hostname.

It runs the same way locally (in a [kind](https://kind.sigs.k8s.io/) cluster) as on integration, and doesn't depend on [govuk-docker](https://github.com/alphagov/govuk-docker) - the two can run side by side.

## How it works

Preview App is a Rails app plus a Sidekiq worker. It never builds or runs anything itself: it asks the Kubernetes API to create ordinary, unprivileged objects in a dedicated `previews` namespace, using a service account that can only manage that one namespace (see `kubernetes/previews/role.yaml`).

### Where images come from

Nothing is built in the cluster. `ImageResolver` finds the image GOV.UK's own GitHub Actions already pushed to `ghcr.io/alphagov/govuk/<repo>`:

- **`main`** - the app's latest release, tagged e.g. `v1234` by its own deploy workflow. Every dependency preview runs `main`, so these work out of the box.
- **any other branch** - the image tagged with the branch's head commit SHA, pushed by the app's "Build image from PR" workflow (with pushing enabled). A preview waits (`waiting_for_image`) until it appears, so you can create one straight after pushing.

On integration, images are pulled through GOV.UK's ECR pull-through cache in front of GHCR (`PREVIEW_APP_IMAGE_REGISTRY`).

### The manifest

`config/govuk_apps.yml` (parsed by `lib/govuk_apps.rb`) lists every app Preview App can preview: its `repo_url` (which must be under `alphagov/`), an optional `database`, optional `dependencies` (other manifest entries that must be running first), optional `setup_tasks` and `worker_command`, `publicly_readable` for a dependency that's safe to make hostname-routable (see Routing), and a fixed `env` hash for anything that app needs pointed at a real GOV.UK service.

### Building a preview

Creating a `Preview` (an app name + branch) enqueues `PreviewsCreateJob`, which delegates to `PreviewBuilder#build!`. This drives the preview through `queued` → `waiting_for_image` → `starting` → `running`, or `failed` at any step:

1. **Dependencies first.** For each app named in the manifest's `dependencies`, in order, build a fresh, dedicated `Preview` (always branch `main`, never shared across parents) recursively, and inject its `PLEK_SERVICE_<NAME>_URI` (`http://<its Service name>`) into the parent's env once it's running. Order matters: each dependency also inherits the resolved `PLEK_SERVICE_*_URI`s of every dependency built *before* it in the same list - e.g. Whitehall's `frontend` dependency, declared after `publishing-api`, ends up pointed at the preview's own Content Store, not Frontend's default of the real GOV.UK one.
2. **Resolve the image** (`ImageResolver`) - see above.
3. **Config overrides** (`ConfigOverrides`) - a fixed initializer, mounted into every pod from a ConfigMap, fixing problems a plain env var can't reach: some apps hardcode an `x_sendfile_header`, some apps' `database.yml` ignores `DATABASE_URL` in production, and some set `config.hosts` to a real GOV.UK-only allowlist that would 403 every preview hostname.
4. **Database**, if the manifest declares one (`KubernetesDatabaseRunner`) - a dedicated, never-shared MySQL/Postgres StatefulSet with its own small volume, then a `db:create db:schema:load` Job and a `db:seed` Job.
5. **Setup tasks**, if the manifest declares any - each named `bin/rails` task, in order, as its own Job (e.g. the taxonomy Whitehall needs in Publishing API before a document can be tagged).
6. **Start** (`KubernetesRunner#start!`) - a Deployment and a Service, waiting until the app is actually serving. If the manifest declares a `worker_command`, a second Deployment runs that from the same image (e.g. Publishing API's Sidekiq worker, which pushes published content to Content Store).

Every object is named by `ContainerName` (the preview's slug, truncated and hashed to fit Kubernetes' 63-character name limit) and labelled with the preview's id.

Every preview pod runs as its image's own non-root user, with no Kubernetes API token, under the `restricted` Pod Security standard - the `previews` namespace rejects anything else.

### Routing

`HostRouter` (a Rack middleware) inspects every request's `Host` header: if it matches a `running`, non-dependency preview's hostname (`<slug>.<PREVIEW_APP_BASE_DOMAIN>`), it proxies straight to that preview's Service, never touching Preview App's own routes. Anything else - Preview App's own UI, or an unmatched/stale subdomain - falls through as normal.

A dependency preview is normally internal-only - never hostname-routable, since most (e.g. Publishing API) are unauthenticated, state-mutating APIs. A manifest entry marked `publicly_readable: true` (e.g. Content Store) is the exception: it's routable at a short, randomised hostname (`Preview#generate_public_hostname`), unique to that one instance.

### Isolation

The `previews` namespace is a security boundary, not just tidiness:

- Preview App's service account can only manage objects in `previews` - not the real apps alongside it in `apps` - and can't read Secrets at all.
- Network policies (`kubernetes/previews/network-policies.yaml`) let previews talk to each other, DNS and the public internet, and let Preview App's web pod in - nothing else. Previews can't reach other namespaces, private address ranges or the cloud metadata service.
- A `ResourceQuota` caps what previews can use between them.

### Tearing down

Deleting a preview enqueues `PreviewsDestroyJob`, which delegates to `PreviewDestroyer#destroy!` - recursively deleting every dependent preview's Kubernetes objects (and database volume) first, then the preview's own.

### Staying honest about what's actually running

`PreviewReconciler` runs at boot and marks any `running` preview `failed` if its Deployment or database no longer exists - e.g. after the local kind cluster was recreated. A pod that merely crashed or was rescheduled doesn't count: Kubernetes recreates it by itself.

## Local development

Prerequisites:

- Docker Desktop (or another Docker engine), with ~6GB of memory to spare for a full Whitehall preview.
- [kind](https://kind.sigs.k8s.io/) and kubectl: `brew install kind kubectl`.
- `*.dev.gov.uk` resolving to `127.0.0.1` - the standard GOV.UK dev machine setup. If `curl -sI http://frontend-main.govuk-preview-app.dev.gov.uk` fails to resolve, add a wildcard rule for the whole domain to your dnsmasq config (e.g. `/opt/homebrew/etc/dnsmasq.d/`):

  ```
  address=/dev.gov.uk/127.0.0.1
  ```

Then:

```
bin/kind-up
```

This creates a single-node kind cluster called `govuk-preview-app`, builds Preview App's image, loads it into the cluster, and applies `kubernetes/local` - the same `previews` namespace objects integration uses (`kubernetes/previews`), plus Preview App itself and its own Postgres and Redis in the `apps` namespace, mirroring integration's layout.

Visit <http://govuk-preview-app.dev.gov.uk:8080/previews>. Once a preview reaches "running", it's reachable at its own hostname, e.g. <http://whitehall-main.govuk-preview-app.dev.gov.uk:8080/>.

Preview App listens on `127.0.0.1:8080` rather than port 80 because govuk-docker's own nginx-proxy already holds port 80 on most GOV.UK dev machines, and only one process can bind a given host port - this way both run side by side. On integration there's no port in any URL.

After changing Preview App's own code, run `bin/kind-deploy` to rebuild and redeploy it (existing previews keep running). `bin/kind-down` deletes the cluster, every preview and Preview App's database.

Every `kubectl` command in these scripts passes `--context kind-govuk-preview-app`, so they can never touch any other cluster. To look around yourself:

```
kubectl --context kind-govuk-preview-app -n previews get pods
```

### Previewing a branch

Any branch whose image has been pushed to GHCR can be previewed locally, exactly as on integration - Preview App never needs the code itself. `main` (and so every dependency) works straight away; other branches need the app's "Build image from PR" workflow to have pushed their image.

### Running the tests

The specs need Postgres and Redis, like any GOV.UK Rails app - e.g. via govuk-docker, or:

```
docker run -d --rm --name preview-app-test-postgres -p 55432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17
export RAILS_ENV=test TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/govuk_preview_app_test
bin/rails db:setup
bin/rails dartsass:build
bundle exec rspec
```

Kubernetes, GitHub and GHCR are all stubbed with WebMock - the specs never need a cluster.
