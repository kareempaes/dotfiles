#!/bin/sh
# Asks every Neovim under $TMPDIR to reload the buffers whose files Claude Code just wrote, and logs each run.
dir="${TMPDIR:-/tmp}"
log="$dir/cs-typein.log"
for s in "$dir"/nvim.*/*/nvim.*.0; do
  [ -S "$s" ] || continue
  out=$(nvim --server "$s" --remote-expr 'luaeval("require(\"config.autocmds\").sync()")' 2>&1)
  rc=$?
  printf '%s %s rc=%s %s\n' "$(date '+%H:%M:%S')" "$s" "$rc" "$out" >> "$log"
done
true
