## Editing files

- Change files with the Edit and Write tools, not shell commands (`sed`, heredocs, `echo >`). A Neovim hook reloads
  open buffers only after those tools, so a shell edit does not show up live.

## Edit review in Neovim

- Edit and Write can pause for the user's review: the PreToolUse hook `~/.claude/hooks/review.py` draws the change in
  the Neovim whose working directory holds the file, and the user accepts (`ga`) or rejects (`gr`). Say what edit is
  coming before you send it, and do not send parallel edits to one file; they queue one at a time.
- "Rejected in Neovim: <reason>" is the user's answer: follow the reason and do not resend the same edit.
- A note that the user revised the edit means the file differs from what you proposed: re-read it before editing it
  again.
- With no Neovim holding the file, edits go through unreviewed. Never get around a rejection with Bash (`sed`,
  heredocs).
- Lock files (`lazy-lock.json`, `go.sum`, `package-lock.json`, `pnpm-lock.yaml`) and git-ignored files skip the
  review. A deny saying the file is generated means run the project's generator; do not edit it.
- The hook logs one JSON line per outcome to `~/.local/state/claude-review/review.jsonl`. If the review misbehaves,
  read the tail of that file before guessing.
