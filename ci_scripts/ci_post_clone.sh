#!/bin/bash
set -euo pipefail

echo "--- Checking swift-format version ---"
swift format --version

echo "--- Running swift-format lint ---"
swift format lint --strict --recursive "$CI_PRIMARY_REPOSITORY_PATH/Pylo"
swift format lint --strict --recursive "$CI_PRIMARY_REPOSITORY_PATH/PyloTests"
swift format lint --strict --recursive "$CI_PRIMARY_REPOSITORY_PATH/Packages"

echo "--- All checks passed ---"
