#!/bin/bash
# Test assertion and result tracking

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

assert_pass() {
  local test_name=$1
  echo -e "${GREEN}[PASS]${NC} $test_name"
  ((TESTS_PASSED++))
}

assert_fail() {
  local test_name=$1
  local reason=${2:-""}
  echo -e "${RED}[FAIL]${NC} $test_name${reason:+ — $reason}"
  ((TESTS_FAILED++))
  FAILED_TESTS+=("$test_name")
}

assert_skip() {
  local test_name=$1
  local reason=${2:-""}
  echo -e "${YELLOW}[SKIP]${NC} $test_name${reason:+ — $reason}"
  ((TESTS_SKIPPED++))
}

print_summary() {
  echo ""
  echo "=============================="
  echo "  Test Summary"
  echo "=============================="
  echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
  echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
  echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
  echo "=============================="
  if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n${RED}Failed tests:${NC}"
    for t in "${FAILED_TESTS[@]}"; do
      echo "  - $t"
    done
  fi
  echo ""
  [ "$TESTS_FAILED" -eq 0 ]
}
