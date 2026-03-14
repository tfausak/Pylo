#!/usr/bin/env sh
set -o errexit -o pipefail -o xtrace

for p in Packages/*
do
  # Skip packages without test targets.
  [ -d "$p/Tests" ] || continue
  # Using the release configuration is 100x faster for the SRP tests.
  swift test --configuration release --package-path "$p"
done

exec xcodebuild \
  -scheme Pylo \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -quiet \
  test "$@" 2>&1
