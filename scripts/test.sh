#!/usr/bin/env sh
set -o errexit -o pipefail -o xtrace

# Run SPM package tests
# SRP uses BigInt which is ~100x slower in debug mode (89s vs 0.9s),
# so build it in release mode.
for pkg in Packages/*/
do
  case "$pkg" in
    *SRP*) swift test -c release --package-path "$pkg" ;;
    *)     swift test --package-path "$pkg" ;;
  esac
done

# Run Xcode scheme tests (iOS Simulator)
xcodebuild \
  -scheme Pylo \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -quiet \
  test "$@" 2>&1 | tee _scratch/test-$( date +%Y-%m-%d-%H-%M-%S ).txt
