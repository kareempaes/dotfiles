#!/bin/sh
# Links the configs into ~/.config and the Claude Code hooks into ~/.claude/hooks, with one system's files
# (macos or linux) as tmux/os.conf and ghostty/os. It never replaces what is there.
set -eu
os=${1:-}
repo=$(cd "$(dirname "$0")" && pwd)
[ -f "$repo/tmux/$os.conf" ] || { echo "usage: $0 macos|linux" >&2; exit 1; }

link() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    echo "skipped $2 (exists)"
    return
  fi
  mkdir -p "$(dirname "$2")"
  ln -s "$1" "$2"
  echo "linked  $2"
}

link "$os.conf" "$repo/tmux/os.conf"
link "$os" "$repo/ghostty/os"
for name in nvim tmux ghostty; do
  link "$repo/$name" "$HOME/.config/$name"
done
for name in review.py typein.sh; do
  link "$repo/claude/hooks/$name" "$HOME/.claude/hooks/$name"
done
