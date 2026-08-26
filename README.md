# gh-actions

Shared GitHub Actions workflows and scaffolding scripts for the `condensed69`
account.

## `/oc` OpenCode review workflow

Posts an AI code review to a PR when a collaborator comments `/oc` (or
`/opencode`).

- **`oc-review.yml`** — the reusable workflow (`workflow_call`). Runs the review:
  primary `opencode-go/qwen3.7-plus`, credential-free `opencode/hy3-free` fallback.
  Single source of truth — fixes here propagate to every consumer on `@main`.
- **`stub/opencode.yml`** — the per-repo caller stub (triggers + guards + `secrets: inherit`).

### Add it to a repo

```bash
./add-oc-review.sh <owner/repo>
```

The script writes the stub, sets the `OPENCODE_GO_API_KEY` secret, and opens a PR.
It reads the key from `$OPENCODE_GO_API_KEY` or from the `AI API Keys (Homelab)`
Bitwarden item (needs `BW_SESSION`).

### Manual install

1. Copy `stub/opencode.yml` to `.github/workflows/opencode.yml` in the target repo.
2. Add the `OPENCODE_GO_API_KEY` secret.

## Requirements

- Target repos must have the `OPENCODE_GO_API_KEY` secret set.
- This repo is **public** because GitHub only lets *public* repos call reusable
  workflows from a *public* repository (private repos can call private or public
  reusable workflows, but public repos can only call public ones). No secrets
  live here — only the secret *name* is referenced.
