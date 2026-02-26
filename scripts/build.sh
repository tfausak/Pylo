#!/usr/bin/env sh
exec xcodebuild \
  -scheme Pylo \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -quiet \
  build "$@"
