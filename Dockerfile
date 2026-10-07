ARG ruby_version=4.0
ARG base_image=ghcr.io/alphagov/govuk-ruby-base:$ruby_version
ARG builder_image=ghcr.io/alphagov/govuk-ruby-builder:$ruby_version

FROM --platform=$TARGETPLATFORM $builder_image AS builder

WORKDIR $APP_HOME
COPY Gemfile* .ruby-version ./
RUN bundle install
COPY . .
RUN bundle exec bootsnap precompile --gemfile .
RUN bundle exec rails assets:precompile && rm -fr log

FROM --platform=$TARGETPLATFORM $base_image

ENV GOVUK_APP_NAME=govuk-preview-app
WORKDIR $APP_HOME

COPY --from=builder $BUNDLE_PATH $BUNDLE_PATH
COPY --from=builder $BOOTSNAP_CACHE_DIR $BOOTSNAP_CACHE_DIR
COPY --from=builder $APP_HOME .

USER app
# Migrations and seeding have standard homes on Integration instead
# (generic-govuk-app's dbMigrationEnabled PreSync job, and nowhere, since
# db:seed is a no-op there - see the govuk-helm-charts PR). The one thing
# left with no generic-govuk-app equivalent is reconciling any previews
# left stale by a restart, which has to live here: unlike
# workers.types[].command for the worker, that chart has no override for
# the main container's command at all.
CMD ["bash", "-c", "bin/rails previews:reconcile && exec bundle exec puma"]
