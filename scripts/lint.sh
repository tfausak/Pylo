#!/usr/bin/env sh
set -o errexit -o pipefail -o xtrace
swift format lint \
  --parallel \
  --recursive \
  --strict \
  Pylo PyloTests Packages "$@" | tee _scratch/lint-$( date +%Y-%m-%d-%H-%M-%S ).txt
