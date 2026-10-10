# gh-actions

Shared GitHub Actions workflows and scaffolding scripts for the `condensed69`
account.

## `/oc` OpenCode review workflow

Posts an AI code review to a PR when a collaborator comments `/oc` (or
`/opencode`).

- **`oc-review.yml`** — the reusable workflow (`workflow_call`). Runs the review:
  primary `minimax-plan/MiniMax-M3.1-Flash-Preview` (25 min limit), fallback
  `opencode/muse-spark-1.3-contributor-free` (10 min limit), so a run with no
  review ends within 35 min.
  The primary is **not** a stock OpenCode provider — `minimax-plan` is declared
  inline in `OPENCODE_CONFIG_CONTENT` against MiniMax's Anthropic-compatible
  endpoint, and it needs a `MINIMAX_API_KEY` secret in the calling repo. Without
  that secret the primary fails and the Zen free fallback answers, so a repo
  installed without it still gets reviews.
  Single source of truth — updates here propagate to every consumer on `@main`.
  A bare `/oc` (ignoring whitespace, case and a trailing Claude Code footer) is a review-only run:
  untracked files are ignored for that run, so scratch files the model leaves
  behind can't be pushed to the PR, and the prompt tells it not to edit or
  commit anything. A tracked-file edit or a commit the model makes itself is
  held back only by that prompt.
  `/oc <instruction>` can still commit changes it was asked to make.
- **`stub/opencode.yml`** — the per-repo caller stub (triggers + guards + `secrets: inherit`).

Do **not** point this workflow at `opencode-go/*` while Go tokens are exhausted.
`nemotron-*-free` is also off-limits: NVIDIA's trial endpoint 404s mid-stream.

### Add it to a repo

```bash
./add-oc-review.sh <owner/repo>
```

The script writes the stub and opens a PR. `MINIMAX_API_KEY` (primary reviewer)
and `OPENCODE_GO_API_KEY` (unused today, kept for a later paid-model swap) are
both optional secrets it sets when the key is available in the environment or in
the Bitwarden item. Without `MINIMAX_API_KEY` the repo still reviews, on the
free fallback model.

### Manual install

1. Copy `stub/opencode.yml` to `.github/workflows/opencode.yml` in the target repo.
2. Add a `MINIMAX_API_KEY` repo secret for the primary reviewer (optional; the
   free fallback answers without it).

## Requirements

- This repo is **public** because GitHub only lets *public* repos call reusable
  workflows from a *public* repository (private repos can call private or public
  reusable workflows, but public repos can only call public ones). No secrets
  live here — only the secret *name* is referenced, and only if a consumer sets it.
