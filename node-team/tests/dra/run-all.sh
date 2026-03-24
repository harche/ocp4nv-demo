#!/bin/bash
# OCPNODE-4170: Run all DRA validation tests
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/assert.sh"

header "OCPNODE-4170: NVIDIA DRA driver validation"

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  test_name="$(basename "$test_script" .sh)"
  header "$test_name"
  bash "$test_script"
  rc=$?
  if [ $rc -eq 0 ]; then
    assert_pass "$test_name"
  elif [ $rc -eq 2 ]; then
    assert_skip "$test_name"
  else
    assert_fail "$test_name"
  fi
done

print_summary
