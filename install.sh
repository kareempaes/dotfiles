#!/bin/sh
# Links the configs into ~/.config and the Claude Code hooks into ~/.claude/hooks. It never replaces what is there.
set -eu
repo=$(cd "$(dirname "$0")" && pwd)

link() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    echo "skipped $2 (exists)"
    return
  fi
  mkdir -p "$(dirname "$2")"
  ln -s "$1" "$2"
  echo "linked  $2"
}

for name in nvim tmux ghostty; do
  link "$repo/$name" "$HOME/.config/$name"
done
for name in review.py typein.sh; do
  link "$repo/claude/hooks/$name" "$HOME/.claude/hooks/$name"
done
