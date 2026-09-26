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

# The docker CLI is needed at runtime: this app builds and runs preview
# containers via the host's Docker socket, rather than running any of that
# itself inside a nested container. docker-buildx-plugin is needed too: most
# GOV.UK apps' own Dockerfiles use BuildKit-only features (e.g. $TARGETPLATFORM).
RUN install_packages docker.io docker-buildx git

ENV GOVUK_APP_NAME=govuk-app-preview
WORKDIR $APP_HOME

COPY --from=builder $BUNDLE_PATH $BUNDLE_PATH
COPY --from=builder $BOOTSNAP_CACHE_DIR $BOOTSNAP_CACHE_DIR
COPY --from=builder $APP_HOME .

USER app
CMD ["puma"]
