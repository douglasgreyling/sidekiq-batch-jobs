#!/usr/bin/env bash
# Every lane has its own BUNDLE_GEMFILE and its own /bundle volume, so a fresh
# lane installs on first use and every run after that is a cheap no-op check.
set -euo pipefail

if ! bundle check >/dev/null 2>&1; then
  echo "→ bundle install (${BUNDLE_GEMFILE:-Gemfile})"
  bundle install
fi

exec "$@"
