# dotfiles

My Neovim (LazyVim), tmux and Ghostty configs for macOS, plus two Claude Code hooks that put Claude's edits in front
of you in Neovim before they land.

## Requirements

- macOS: tmux yanks through `pbcopy`, the review hook pings with `afplay`, and Ghostty turns Option into Alt.
- Ghostty, tmux and Neovim 0.12.
- `git`, `curl`, `python3`, `ripgrep` and `fd` on `PATH`.
- `ANTHROPIC_API_KEY` exported in the shell that starts Neovim. Completions (minuet), `<leader>ak` and the review side
  chat call the Claude API with it, on your account.
- Claude Code, for the edit review.

With [Homebrew](https://brew.sh):

```sh
brew install neovim tmux ripgrep fd
brew install --cask ghostty
```

`git`, `curl`, `python3` and the C compiler that builds the syntax parsers come with Apple's command line tools
(`xcode-select --install`).

Optional: Neovim downloads its language servers and formatters by itself on first start, and many of them need Node
or Go to install; `<leader>gg` opens `lazygit`. The editor works without all three.

```sh
brew install node go lazygit
```

## Install

Move your current configs aside first; `install.sh` skips any path that exists:

```sh
for name in nvim tmux ghostty; do
  [ -e ~/.config/$name ] && mv ~/.config/$name ~/.config/$name.bak
done
```

```sh
git clone https://github.com/kareempaes/dotfiles ~/development/dotfiles
~/development/dotfiles/install.sh
```

`install.sh` symlinks `nvim`, `tmux` and `ghostty` into `~/.config` and the two hooks into `~/.claude/hooks`. The first
`nvim` start installs the plugins at the commits pinned in `nvim/lazy-lock.json`; if you used Neovim before, moving
`~/.local/share/nvim` aside as well gives them a clean start.

Ghostty also reads `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` after this config; leave that
file empty.

## Update and remove

The symlinks point into the clone, so `git pull` there updates everything: restart Neovim and Ghostty, and reload
tmux with `C-a r`.

To remove it, delete the links (the clone is untouched) and move your `.bak` configs back:

```sh
rm ~/.config/nvim ~/.config/tmux ~/.config/ghostty ~/.claude/hooks/review.py ~/.claude/hooks/typein.sh
```

If you set up the edit review, also take its two entries out of `~/.claude/settings.json`.

## Reviewing Claude Code's edits in Neovim

1. Merge `claude/settings.example.json` into `~/.claude/settings.json`.
2. Append `claude/instructions.md` to `~/.claude/CLAUDE.md`, so Claude knows what a rejection means.
3. Start Neovim in the project directory and Claude Code in another tmux pane.

Each Edit or Write then waits, drawn inline in the buffer, until you decide:

| Key | Action |
| --- | --- |
| `]c` / `[c` | next / previous hunk |
| `<leader>ay` / `<leader>an` | accept / reject the hunk in focus |
| `<leader>au` | undo that decision |
| `ga` | accept everything still undecided |
| `gr` | reject the whole edit, with an optional reason |
| `<leader>ai` | show Claude's reason for the edit |
| `<leader>ae` | side chat that revises the proposal |
| `<leader>aA` | toggle auto-accept ("review: auto" in the statusline) |

With no Neovim open on the file's directory, edits go through Claude Code's normal flow. `<leader>ak` asks Claude to
change the selected lines and shows the result through the same review.

## Keys

tmux (prefix `C-a`): `|` and `-` split in the current directory, `h` `j` `k` `l` move between panes, `H` `J` `K` `L`
resize, `r` reloads the config; copy mode uses vi keys (`v` selects, `y` yanks to the clipboard).

Ghostty: `Cmd+,` opens its config in Neovim.

Neovim, on top of LazyVim's defaults (`nvim/lua/config/keymaps.lua`):

| Key | Action |
| --- | --- |
| Option+Left / Right | word back / forward |
| Option+Up / Down | previous / next statement |
| Option+Shift+arrows | select by word or line |
| Option+Shift+[ / ] | previous / next buffer |
| Option+1..9 | go to buffer N |
| Option+P, Option+E, Option+O | find files, explorer, LSP symbols |
| Option+Shift+F, Option+Shift+H | grep, search and replace |
| Option+S, Option+W | save, close buffer |
| Option+/, Option+. | toggle comment, code action |
| Option+: | command palette |
| Option+` | terminal |
| Option+Shift+A, Option+A | accept a completion: all of it, one line |
