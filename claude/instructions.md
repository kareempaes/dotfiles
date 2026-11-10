## Editing files

- Change files with the Edit and Write tools where you can, not shell commands (`sed`, heredocs, `echo >`): the user
  reviews an Edit or Write before it is written, a shell change only after it has landed.

## Edit review in Neovim

- Edit and Write can pause for the user's review: the PreToolUse hook `~/.claude/hooks/review.py` draws the change in
  the Neovim whose working directory holds the file, and the user accepts (`ga`) or rejects (`gr`). Say what edit is
  coming before you send it, and do not send parallel edits to one file; they queue one at a time.
- "Rejected in Neovim: <reason>" is the user's answer: follow the reason and do not resend the same edit.
- A note that the user revised the edit means the file differs from what you proposed: re-read it before editing it
  again.
- A Bash command that changes files in a git repository is reviewed the same way after it ran, one file at a time,
  and the command's result waits for it. A note that a file was "rejected and put back as it was" means that change
  is undone on disk; "only part of the change was kept" means the file differs from what the command wrote. Read
  the file again, follow the reason and do not repeat the change.
- With no Neovim holding the file, edits go through unreviewed. Never get around a rejection with another tool or
  command.
- Lock files (`lazy-lock.json`, `go.sum`, `package-lock.json`, `pnpm-lock.yaml`) and git-ignored files skip the
  review. A deny saying the file is generated means run the project's generator; do not edit it.
- The hook logs one JSON line per outcome to `~/.local/state/claude-review/review.jsonl`. If the review misbehaves,
  read the tail of that file before guessing.
