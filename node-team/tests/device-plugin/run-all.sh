#!/bin/bash
# OCPNODE-4138: Run all device-plugin validation tests
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/assert.sh"

header "OCPNODE-4138: NVIDIA GPU Operator (device-plugin mode) validation"

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  test_name="$(basename "$test_script" .sh)"
  header "$test_name"
  if bash "$test_script"; then
    assert_pass "$test_name"
  else
    assert_fail "$test_name"
  fi
done

print_summary
