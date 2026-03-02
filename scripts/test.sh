#!/usr/bin/env sh
set -o errexit -o pipefail -o xtrace

# Run SPM package tests
for pkg in Packages/*/
do
  swift test --package-path "$pkg"
done

# Run Xcode scheme tests (iOS Simulator)
xcodebuild \
  -scheme Pylo \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -quiet \
  test "$@" 2>&1 | tee _scratch/test-$( date +%Y-%m-%d-%H-%M-%S ).txt
