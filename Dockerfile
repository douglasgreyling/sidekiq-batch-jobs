# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.1.7
FROM ruby:${RUBY_VERSION}

ARG BUNDLER_VERSION=

ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential git libpq-dev \
 && rm -rf /var/lib/apt/lists/*

RUN git config --system --add safe.directory /gem

RUN if [ -n "${BUNDLER_VERSION}" ]; then \
      gem install bundler --version "${BUNDLER_VERSION}" --no-document; \
    else \
      gem install bundler --no-document; \
    fi

WORKDIR /gem

COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENTRYPOINT ["entrypoint"]
CMD ["bash"]
