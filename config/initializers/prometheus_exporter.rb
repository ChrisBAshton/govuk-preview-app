# govuk_app_config's GovukPuma always tries to push metrics to a Prometheus
# Exporter server (expected as a sidecar in real deployments); nothing runs
# one locally, so every attempt logs a "Connection refused" error - noisy
# enough to drown out everything else. It's harmless either way (metrics are
# just dropped), so just stop it from logging failures instead of running a
# local exporter server nothing here would read from.
require "prometheus_exporter/client"

PrometheusExporter::Client.default = PrometheusExporter::Client.new(log_level: Logger::FATAL)
