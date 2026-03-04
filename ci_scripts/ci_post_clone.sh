#!/usr/bin/env sh
set -o errexit -o pipefail -o xtrace

cd "$CI_PRIMARY_REPOSITORY_PATH"
exec scripts/lint.sh
