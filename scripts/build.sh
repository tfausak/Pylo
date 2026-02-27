#!/usr/bin/env sh
set -o xtrace
exec xcodebuild \
  -scheme Pylo \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -quiet \
  build "$@" 2>&1 | tee _scratch/build-$( date +%Y-%m-%d-%H-%M-%S ).txt
