# gh-actions

Shared GitHub Actions workflows and scaffolding scripts for the `condensed69`
account.

## `/oc` OpenCode review workflow

Posts an AI code review to a PR when a collaborator comments `/oc` (or
`/opencode`).

- **`oc-review.yml`** — the reusable workflow (`workflow_call`). Runs the review:
  primary `opencode/muse-spark-1.2-contributor-free`, fallback
  `opencode/mimo-v2.5-free`. Both are Zen **free** (no OpenCode Go quota, no
  API key). Single source of truth — updates here propagate to every consumer on `@main`.
- **`stub/opencode.yml`** — the per-repo caller stub (triggers + guards + `secrets: inherit`).

Do **not** point this workflow at `opencode-go/*` while Go tokens are exhausted.
`nemotron-*-free` is also off-limits: NVIDIA's trial endpoint 404s mid-stream.

### Add it to a repo

```bash
./add-oc-review.sh <owner/repo>
```

The script writes the stub and opens a PR. An `OPENCODE_GO_API_KEY` secret is
optional (the current free models do not use it). If the env var or Bitwarden
item is present, the script still sets the secret so a later paid-model swap
does not need a second install pass.

### Manual install

1. Copy `stub/opencode.yml` to `.github/workflows/opencode.yml` in the target repo.
2. No API-key secret is required for the current Zen-free models.

## Requirements

- This repo is **public** because GitHub only lets *public* repos call reusable
  workflows from a *public* repository (private repos can call private or public
  reusable workflows, but public repos can only call public ones). No secrets
  live here — only the secret *name* is referenced, and only if a consumer sets it.
