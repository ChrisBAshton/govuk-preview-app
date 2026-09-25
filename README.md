# GOV.UK App Preview

A lightweight orchestrator for running disposable, branch-specific preview instances of GOV.UK applications. It checks out a requested branch, builds the application's own Dockerfile, allocates it a port, and runs it — so, for example, several branches of Whitehall (each with its own dependencies) can be previewed simultaneously without reproducing the full GOV.UK development or production Kubernetes architecture.

See [govuk-docker](https://github.com/alphagov/govuk-docker) for the equivalent local-development tool, which this project deliberately does not depend on.
