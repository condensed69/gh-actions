#!/usr/bin/env bash
set -euo pipefail

# add-oc-review.sh — install the /oc OpenCode review workflow into a repo.
#
# Usage:
#   add-oc-review.sh <owner/repo>
#
# The workflow is a thin stub that calls the shared reusable workflow in
# condensed69/gh-actions, so future fixes propagate automatically. The script
# also sets the OPENCODE_GO_API_KEY secret (required for the primary Qwen model).
#
# Requirements: gh (authenticated), git.
#
# The API key is resolved from, in order:
#   1. the OPENCODE_GO_API_KEY environment variable
#   2. the Bitwarden CLI (bw with $BW_SESSION set) -> "AI API Keys (Homelab)" item
#
# The stub is committed on a branch and opened as a PR (never pushed straight to
# main), so it can be reviewed before it goes live.

REPO="${1:?usage: add-oc-review.sh <owner/repo>}"
WORKFLOW_REPO="condensed69/gh-actions"
STUB_PATH="stub/opencode.yml"
BRANCH="chore/add-oc-review"

for cmd in gh git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' is required" >&2; exit 1; }
done

# --- resolve OPENCODE_GO_API_KEY ---
if [[ -z "${OPENCODE_GO_API_KEY:-}" ]] && command -v bw >/dev/null 2>&1 && [[ -n "${BW_SESSION:-}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: 'jq' is required for the Bitwarden lookup" >&2
    exit 1
  fi
  OPENCODE_GO_API_KEY="$(bw get item 'AI API Keys (Homelab)' --session "$BW_SESSION" \
    | jq -r '.fields[]? | select(.name == "OPENCODE_ZEN_API_KEY") | .value' \
    | grep -v '^null$' || true)"
fi

if [[ -z "${OPENCODE_GO_API_KEY:-}" ]]; then
  cat >&2 <<'MSG'
OPENCODE_GO_API_KEY is not set and could not be resolved from Bitwarden.
Set it explicitly and retry, e.g.:
    export OPENCODE_GO_API_KEY='sk-...'
(The key lives in the "AI API Keys (Homelab)" Bitwarden item, field OPENCODE_ZEN_API_KEY.)
MSG
  exit 1
fi

# --- fetch the stub from the shared repo (single source of truth) ---
STUB="$(gh api "repos/$WORKFLOW_REPO/contents/$STUB_PATH" \
  -H 'Accept: application/vnd.github.raw' 2>/dev/null)" || {
  echo "error: could not fetch $STUB_PATH from $WORKFLOW_REPO" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --quiet "https://github.com/$REPO.git" "$TMP/repo"
cd "$TMP/repo"

mkdir -p .github/workflows
printf '%s\n' "$STUB" > .github/workflows/opencode.yml

git checkout -b "$BRANCH"
git add .github/workflows/opencode.yml
git commit -m "ci: add /oc OpenCode review workflow"
git -c credential.helper='!gh auth git-credential' push -u origin "$BRANCH"

printf '%s' "$OPENCODE_GO_API_KEY" | gh secret set OPENCODE_GO_API_KEY -R "$REPO"

gh pr create -R "$REPO" --base main --head "$BRANCH" \
  --title "ci: add /oc OpenCode review workflow" \
  --body "Adds the \`/oc\` review workflow (thin stub -> \`$WORKFLOW_REPO\` reusable workflow) and sets the \`OPENCODE_GO_API_KEY\` secret."
