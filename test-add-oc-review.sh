#!/usr/bin/env bash
set -euo pipefail

# test-add-oc-review.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TO_TEST="$SCRIPT_DIR/add-oc-review.sh"

TEST_TMP=""
MOCK_BIN=""
LOG_DIR=""

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="$TEST_TMP/bin"
  LOG_DIR="$TEST_TMP/log"
  mkdir -p "$MOCK_BIN" "$LOG_DIR"

  export PATH="$MOCK_BIN:$PATH"

  # Clear environment variables
  unset OPENCODE_GO_API_KEY || true
  unset BW_SESSION || true
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

create_mock() {
  local cmd="$1"
  local body="$2"
  cat <<EOF > "$MOCK_BIN/$cmd"
#!/usr/bin/env bash
echo "$cmd \$@" >> "$LOG_DIR/${cmd}.log"
$body
EOF
  chmod +x "$MOCK_BIN/$cmd"
}

assert_success() {
  "$@" > "$LOG_DIR/out" 2> "$LOG_DIR/err" || {
    echo "Expected success but got failure: $*"
    echo "stdout:"
    cat "$LOG_DIR/out"
    echo "stderr:"
    cat "$LOG_DIR/err"
    return 1
  }
}

assert_failure() {
  if "$@" > "$LOG_DIR/out" 2> "$LOG_DIR/err"; then
    echo "Expected failure but got success: $*"
    echo "stdout:"
    cat "$LOG_DIR/out"
    echo "stderr:"
    cat "$LOG_DIR/err"
    return 1
  fi
}

assert_log_contains() {
  local file="$1"
  local pattern="$2"
  if [ ! -f "$LOG_DIR/$file" ]; then
    echo "Expected log '$file' does not exist."
    return 1
  fi
  if ! grep -qE "$pattern" "$LOG_DIR/$file"; then
    echo "Expected log '$file' to contain '$pattern'"
    echo "Contents of $file:"
    cat "$LOG_DIR/$file"
    return 1
  fi
}

run_test() {
  local name="$1"
  echo "Running test: $name"
  setup

  # Ensure cleanup happens even if the test fails
  trap teardown EXIT

  "test_$name"

  # Manual teardown for successful runs
  trap - EXIT
  teardown
  echo "Passed: $name"
}

# --- Tests ---

test_missing_args() {
  assert_failure "$SCRIPT_TO_TEST"
  assert_log_contains err "usage: add-oc-review.sh <owner/repo>"
}

test_missing_gh() {
  create_mock git ""
  # Intentionally not creating gh mock
  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: 'gh' is required"
}

test_happy_path_no_api_key() {
  create_mock gh '
    if [[ "$*" == *"api repos/condensed69/gh-actions/contents/stub/opencode.yml"* ]]; then
      echo "dummy-stub-content"
    fi
  '
  create_mock git '
    if [[ "$1" == "clone" ]]; then
      # $1=clone, $2=--quiet, $3=url, $4=path
      mkdir -p "$4"
    fi
  '

  assert_success "$SCRIPT_TO_TEST" "owner/repo"

  assert_log_contains out "note: OPENCODE_GO_API_KEY not set"
  assert_log_contains gh.log "api repos/condensed69/gh-actions/contents/stub/opencode.yml"
  assert_log_contains git.log "clone --quiet https://github.com/owner/repo.git"
  assert_log_contains git.log "checkout -b chore/add-oc-review"
  assert_log_contains git.log "add .github/workflows/opencode.yml"
  assert_log_contains git.log "commit -m ci: add /oc OpenCode review workflow"
  assert_log_contains git.log "push -u origin chore/add-oc-review"
  assert_log_contains gh.log "pr create -R owner/repo"

  # Ensure secret set is NOT called
  if [ -f "$LOG_DIR/gh.log" ] && grep -q "secret set" "$LOG_DIR/gh.log" 2>/dev/null; then
    echo "Expected no secret set call"
    return 1
  fi
}

test_happy_path_with_env_api_key() {
  create_mock gh "
    if [[ \"\$*\" == *\"api repos/condensed69/gh-actions/contents/stub/opencode.yml\"* ]]; then
      echo \"dummy-stub-content\"
    fi
    if [[ \"\$*\" == *\"secret set\"* ]]; then
      cat - > \"$LOG_DIR/gh_stdin\"
    fi
  "
  create_mock git '
    if [[ "$1" == "clone" ]]; then
      mkdir -p "$4"
    fi
  '

  export OPENCODE_GO_API_KEY="test-api-key-from-env"
  assert_success "$SCRIPT_TO_TEST" "owner/repo"

  assert_log_contains gh.log "secret set OPENCODE_GO_API_KEY -R owner/repo"
  assert_log_contains gh_stdin "test-api-key-from-env"
}

test_happy_path_with_bw_api_key() {
  create_mock gh "
    if [[ \"\$*\" == *\"api repos/condensed69/gh-actions/contents/stub/opencode.yml\"* ]]; then
      echo \"dummy-stub-content\"
    fi
    if [[ \"\$*\" == *\"secret set\"* ]]; then
      cat - > \"$LOG_DIR/gh_stdin\"
    fi
  "
  create_mock git '
    if [[ "$1" == "clone" ]]; then
      mkdir -p "$4"
    fi
  '
  create_mock bw '
    if [[ "$*" == *"get item AI API Keys (Homelab) --session test-session"* ]]; then
      echo "dummy-bw-json"
    fi
  '
  create_mock jq '
    echo "test-api-key-from-bw"
  '

  export BW_SESSION="test-session"
  assert_success "$SCRIPT_TO_TEST" "owner/repo"

  assert_log_contains bw.log "get item AI API Keys \(Homelab\) --session test-session"
  assert_log_contains jq.log "\.fields\[\]\? \| select\(\.name == \"OPENCODE_ZEN_API_KEY\"\)"

  assert_log_contains gh.log "secret set OPENCODE_GO_API_KEY -R owner/repo"
  assert_log_contains gh_stdin "test-api-key-from-bw"
}

test_bw_no_jq() {
  # To reach the jq check, bw must exist and succeed in command -v
  create_mock gh ""
  create_mock git ""
  create_mock bw ""

  # Set up a PATH that excludes jq
  local OLD_PATH="$PATH"
  local TEMP_BIN="$TEST_TMP/fake_bin"
  mkdir -p "$TEMP_BIN"
  ln -s "$(which bash)" "$TEMP_BIN/bash"
  ln -s "$(which echo)" "$TEMP_BIN/echo"
  ln -s "$(which cat)" "$TEMP_BIN/cat"
  ln -s "$(which grep)" "$TEMP_BIN/grep"
  ln -s "$(which mktemp)" "$TEMP_BIN/mktemp"
  ln -s "$(which rm)" "$TEMP_BIN/rm"
  ln -s "$(which ls)" "$TEMP_BIN/ls"

  export PATH="$MOCK_BIN:$TEMP_BIN"
  export BW_SESSION="test-session"

  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: 'jq' is required for the Bitwarden lookup"

  export PATH="$OLD_PATH"
}

run_test missing_args
run_test missing_gh
run_test happy_path_no_api_key
run_test happy_path_with_env_api_key
run_test happy_path_with_bw_api_key
run_test bw_no_jq

echo "All tests passed!"
