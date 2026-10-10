#!/usr/bin/env bash
set -euo pipefail

# add-oc-review.sh — install the /oc OpenCode review workflow into a repo.
#
# Usage:
#   add-oc-review.sh <owner/repo>
#
# The workflow is a thin stub that calls the shared reusable workflow in
# condensed69/gh-actions, so future updates propagate automatically.
#
# The review workflow's primary reviewer is MiniMax M3.1 Flash Preview, which
# needs MINIMAX_API_KEY in the target repo. Its Zen free fallback
# (muse-spark) needs no key, so a repo installed without the secret still
# gets reviews - just from the fallback model.
#
# Two secrets are set, both optional:
#   MINIMAX_API_KEY        the M Plan key for the primary reviewer
#   OPENCODE_GO_API_KEY    not used by any model in the chain today; set
#                          anyway so a later paid-model swap needs no
#                          second install pass
#
# Requirements: gh (authenticated), git.
#
# Each key is resolved from, in order:
#   1. the matching environment variable
#   2. the Bitwarden CLI (bw with $BW_SESSION set) -> "AI API Keys (Homelab)" item
#      field OPENCODE_ZEN_API_KEY or MINIMAX_API_KEY
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

# --- resolve API keys (optional) ---
if { [[ -z "${OPENCODE_GO_API_KEY:-}" ]] || [[ -z "${MINIMAX_API_KEY:-}" ]]; } \
   && command -v bw >/dev/null 2>&1 && [[ -n "${BW_SESSION:-}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: 'jq' is required for the Bitwarden lookup" >&2
    exit 1
  fi
  [[ -n "${OPENCODE_GO_API_KEY:-}" ]] || OPENCODE_GO_API_KEY="$(bw get item 'AI API Keys (Homelab)' --session "$BW_SESSION" \
    | jq -r '.fields[]? | select(.name == "OPENCODE_ZEN_API_KEY") | .value' \
    | grep -v '^null$' || true)"
  [[ -n "${MINIMAX_API_KEY:-}" ]] || MINIMAX_API_KEY="$(bw get item 'AI API Keys (Homelab)' --session "$BW_SESSION" \
    | jq -r '.fields[]? | select(.name == "MINIMAX_API_KEY") | .value' \
    | grep -v '^null$' || true)"
fi

if [[ -z "${OPENCODE_GO_API_KEY:-}" ]]; then
  echo "note: OPENCODE_GO_API_KEY not set; skipping secret (no model in the chain uses it)"
fi

if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
  echo "note: MINIMAX_API_KEY not set; skipping secret (the Zen free reviewer will answer instead)"
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

if [[ -n "${OPENCODE_GO_API_KEY:-}" ]]; then
  printf '%s' "$OPENCODE_GO_API_KEY" | gh secret set OPENCODE_GO_API_KEY -R "$REPO"
fi

if [[ -n "${MINIMAX_API_KEY:-}" ]]; then
  printf '%s' "$MINIMAX_API_KEY" | gh secret set MINIMAX_API_KEY -R "$REPO"
fi

gh pr create -R "$REPO" --base main --head "$BRANCH" \
  --title "ci: add /oc OpenCode review workflow" \
  --body "Adds the \`/oc\` review workflow (thin stub -> \`$WORKFLOW_REPO\` reusable workflow). Primary reviewer is MiniMax M3.1 Flash Preview, which needs the \`MINIMAX_API_KEY\` secret; without it the Zen free reviewer answers instead."
