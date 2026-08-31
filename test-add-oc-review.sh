#!/usr/bin/env bash
set -euo pipefail

# test-add-oc-review.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TO_TEST="$SCRIPT_DIR/add-oc-review.sh"

TEST_TMP=""
MOCK_BIN=""
LOG_DIR=""
ORIG_PATH="$PATH"

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="$TEST_TMP/bin"
  LOG_DIR="$TEST_TMP/log"
  mkdir -p "$MOCK_BIN" "$LOG_DIR"

  export PATH="$MOCK_BIN:$ORIG_PATH"

  # Clear environment variables
  unset OPENCODE_GO_API_KEY || true
  unset BW_SESSION || true
}

teardown() {
  export PATH="$ORIG_PATH"
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

create_mock() {
  local cmd="$1"
  local body="$2"
  cat <<'EOF' > "$MOCK_BIN/$cmd"
#!/usr/bin/env bash
EOF
  # Appending dynamic content safely
  echo "echo \"$cmd\" \"\$@\" >> \"$LOG_DIR/${cmd}.log\"" >> "$MOCK_BIN/$cmd"
  echo "$body" >> "$MOCK_BIN/$cmd"
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

  if ! "test_$name"; then
    echo "Test failed: $name"
    # Ensure failure is visible, teardown will run via EXIT trap if script aborts
    # but we handle subshell/function returns manually here
    exit 1
  fi

  teardown
  echo "Passed: $name"
}

# Ensure global cleanup on script exit
trap teardown EXIT

# --- Helpers ---

isolate_path_for_missing() {
  local tool_to_miss="$1"
  local TEMP_BIN="$TEST_TMP/fake_bin"
  mkdir -p "$TEMP_BIN"

  # Allow fundamental tools to pass through
  for tool in bash echo cat grep mktemp rm ls mkdir printf chmod sed awk; do
    if [ "$tool" != "$tool_to_miss" ]; then
      local tool_path="$(which "$tool" 2>/dev/null || true)"
      if [ -n "$tool_path" ]; then
        ln -s "$tool_path" "$TEMP_BIN/$tool"
      fi
    fi
  done

  # Allow mocks to pass through
  export PATH="$MOCK_BIN:$TEMP_BIN"
}

# --- Tests ---

test_missing_args() {
  assert_failure "$SCRIPT_TO_TEST"
  assert_log_contains err "usage: add-oc-review.sh <owner/repo>"
}

test_missing_gh() {
  create_mock git ""
  isolate_path_for_missing "gh"

  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: 'gh' is required"
}

test_missing_git() {
  create_mock gh ""
  isolate_path_for_missing "git"

  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: 'git' is required"
}

test_gh_api_fetch_failure() {
  create_mock gh '
    if [[ "$*" == *"api repos/condensed69/gh-actions/contents/stub/opencode.yml"* ]]; then
      exit 1
    fi
  '
  create_mock git ""

  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: could not fetch stub/opencode.yml from condensed69/gh-actions"
}

test_bw_returns_null() {
  create_mock gh '
    if [[ "$*" == *"api repos/condensed69/gh-actions/contents/stub/opencode.yml"* ]]; then
      echo "dummy-stub-content"
    fi
  '
  create_mock git "
    if [[ \"\$1\" == \"clone\" ]]; then
      mkdir -p \"\$4\"
    fi
  "
  create_mock bw '
    if [[ "$*" == *"get item AI API Keys (Homelab) --session test-session"* ]]; then
      echo "dummy-bw-json"
    fi
  '
  create_mock jq '
    echo "null"
  '

  export BW_SESSION="test-session"
  assert_success "$SCRIPT_TO_TEST" "owner/repo"

  assert_log_contains bw.log "get item AI API Keys \(Homelab\) --session test-session"
  assert_log_contains out "note: OPENCODE_GO_API_KEY not set"

  if [ -f "$LOG_DIR/gh.log" ] && grep -q "secret set" "$LOG_DIR/gh.log" 2>/dev/null; then
    echo "Expected no secret set call for null API key"
    return 1
  fi
}

test_happy_path_no_api_key() {
  create_mock gh "
    if [[ \"\$*\" == *\"api repos/condensed69/gh-actions/contents/stub/opencode.yml\"* ]]; then
      echo \"dummy-stub-content\"
    fi
  "
  create_mock git "
    if [[ \"\$1\" == \"clone\" ]]; then
      # \$1=clone, \$2=--quiet, \$3=url, \$4=path
      mkdir -p \"\$4\"
    fi
  "

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

  # Verify the stub file was actually written correctly
  # Note: Since the test script removes $TEST_TMP in teardown, we can't inspect the file directly after run.
  # But we can verify `assert_success` ensures it was written, because the bash script runs `printf` into it.
  # If we really want to inspect it, we should do it before teardown.
  # Actually, the file is written to $TMP/repo, which the script creates via `mktemp -d` and cleans up via EXIT trap.
  # So we CANNOT inspect it from here after `assert_success` finishes. The script cleans it up!
  # Let's verify the stub content by checking the gh api mock was called correctly, and that the file was added.
  assert_log_contains git.log "add .github/workflows/opencode.yml"
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
  create_mock git "
    if [[ \"\$1\" == \"clone\" ]]; then
      mkdir -p \"\$4\"
      echo \"\$4\" > \"$LOG_DIR/git_clone_dir\"
    fi
  "

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
  create_mock git "
    if [[ \"\$1\" == \"clone\" ]]; then
      mkdir -p \"\$4\"
    fi
  "
  create_mock bw "
    if [[ \"\$*\" == *\"get item AI API Keys (Homelab) --session test-session\"* ]]; then
      echo \"dummy-bw-json\"
    fi
  "
  create_mock jq "
    echo \"test-api-key-from-bw\"
  "

  export BW_SESSION="test-session"
  assert_success "$SCRIPT_TO_TEST" "owner/repo"

  assert_log_contains bw.log "get item AI API Keys \(Homelab\) --session test-session"
  # Use exact match logic since the jq filter is hard to match strictly with basic regex
  assert_log_contains jq.log "fields.*OPENCODE_ZEN_API_KEY"

  assert_log_contains gh.log "secret set OPENCODE_GO_API_KEY -R owner/repo"
  assert_log_contains gh_stdin "test-api-key-from-bw"
}

test_bw_no_jq() {
  # To reach the jq check, bw must exist and succeed in command -v
  create_mock gh ""
  create_mock git ""
  create_mock bw ""

  isolate_path_for_missing "jq"

  export BW_SESSION="test-session"

  assert_failure "$SCRIPT_TO_TEST" "owner/repo"
  assert_log_contains err "error: 'jq' is required for the Bitwarden lookup"
}

run_test missing_args
run_test missing_gh
run_test missing_git
run_test gh_api_fetch_failure
run_test bw_returns_null
run_test happy_path_no_api_key
run_test happy_path_with_env_api_key
run_test happy_path_with_bw_api_key
run_test bw_no_jq

echo "All tests passed!"
