-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Option+Left/Right jump by word, as in the shell. Ghostty's stock binds turn them into
-- Esc-b / Esc-f (readline's word motions), which reach Neovim as <M-b> / <M-f>. Unmapped,
-- an Alt chord acts as <Esc> plus the key (:h i_ALT): Option+Left dropped Insert mode and
-- Option+Right left `f` waiting for a character. <M-Left>/<M-Right> cover terminals that
-- send the arrows themselves. Terminal mode is left alone so the inner shell gets the bytes.
local map = vim.keymap.set
for _, key in ipairs({ "<M-b>", "<M-Left>" }) do
  map({ "i", "c" }, key, "<C-Left>", { desc = "Word back" })
  map({ "n", "x", "o" }, key, "b", { desc = "Word back" })
end
for _, key in ipairs({ "<M-f>", "<M-Right>" }) do
  map({ "i", "c" }, key, "<C-Right>", { desc = "Word forward" })
  map({ "n", "x", "o" }, key, "w", { desc = "Word forward" })
end

-- Option+Up/Down jump to the previous/next statement (an assignment, a call, a return, a
-- declaration) through the treesitter text objects LazyVim ships, so they move faster than a
-- line and finer than a paragraph. Function boundaries count too, since Go and Rust only mark
-- statements inside a block, and so do declarations through @declaration.outer, our own
-- capture (Go only: after/queries/go/textobjects.scm; Go's @class.outer would also match
-- every composite literal). A buffer without a statement query (markdown, json, svelte,
-- plain text) falls back to paragraph jumps. On the command line they act like plain Up/Down
-- (history) instead of cancelling the line.
local statement_queries = { "@statement.outer", "@function.outer", "@declaration.outer" }

local function has_statements(buf)
  if not LazyVim.treesitter.have(buf, "textobjects") then
    return false
  end
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  local query = lang and vim.treesitter.query.get(lang, "textobjects")
  return query ~= nil and vim.tbl_contains(query.captures, "statement.outer")
end

local function jump_statement(forward)
  return function()
    if not has_statements(0) then
      vim.cmd("normal! " .. (forward and "}" or "{"))
      return
    end
    if vim.api.nvim_get_mode().mode == "no" then
      -- After an operator the plugin selects up to the target in Visual mode, which would
      -- also eat the target statement's first character; exclude it, as `d}` would.
      local selection = vim.o.selection
      vim.o.selection = "exclusive"
      vim.schedule(function()
        vim.o.selection = selection
      end)
    end
    local move = require("nvim-treesitter-textobjects.move")
    local go = forward and move.goto_next_start or move.goto_previous_start
    go(statement_queries, "textobjects")
  end
end

map({ "n", "x", "o", "i" }, "<M-Up>", jump_statement(false), { desc = "Prev statement" })
map({ "n", "x", "o", "i" }, "<M-Down>", jump_statement(true), { desc = "Next statement" })
map("c", "<M-Up>", "<Up>")
map("c", "<M-Down>", "<Down>")

-- Option+Shift+arrows select as in VSCode: a word left/right, a line up/down (hold to repeat),
-- through 'keymodel' (options.lua). It drops the Shift before moving, and an Alt arrow moves one
-- character, so the word keys go through Ctrl. Mapped in Insert and on the : line too, where an
-- unmapped Alt chord would act as <Esc> plus the key.
map({ "n", "x", "i", "c" }, "<M-S-Left>", "<C-S-Left>", { desc = "Select word back" })
map({ "n", "x", "i", "c" }, "<M-S-Right>", "<C-S-Right>", { desc = "Select word forward" })
map({ "n", "x", "i", "c" }, "<M-S-Up>", "<S-Up>", { desc = "Select line up" })
map({ "n", "x", "i", "c" }, "<M-S-Down>", "<S-Down>", { desc = "Select line down" })

-- Option+Shift+[ / ] cycle the bufferline tabs, as Cmd+Shift+[ / ] does in VSCode (Ghostty keeps
-- that chord for its own tabs). Through tmux the chord arrives as <M-{>/<M-}>; straight from
-- Ghostty, which Neovim switches to the kitty keyboard protocol, as <M-S-[>/<M-S-]>. From Insert
-- they leave it, as LazyVim's <C-s> does, so typing never lands in the next file.
for _, key in ipairs({ "<M-{>", "<M-S-[>" }) do
  map({ "n", "i", "x" }, key, "<cmd>BufferLineCyclePrev<cr><esc>", { desc = "Prev Buffer" })
end
for _, key in ipairs({ "<M-}>", "<M-S-]>" }) do
  map({ "n", "i", "x" }, key, "<cmd>BufferLineCycleNext<cr><esc>", { desc = "Next Buffer" })
end

-- VSCode's Cmd chords on Option, since Cmd never reaches the terminal. Each remaps to the
-- LazyVim key it stands for, as LazyVim's own <leader>e does, and from Insert mode leaves it
-- first: unmapped there, an Alt chord acts as <Esc> plus the key, so Option+. would repeat the
-- last change and Option+o open a line. Not on Option: b/f (what Option+Left/Right send), j/k
-- (move line), n (next reference; plugins/lsp.lua frees p), and Shift+O, Shift+P, [, ], \,
-- which send the Esc-O, Esc-P, Esc-[... that open terminal control sequences. Option+: has two
-- names, like the brackets.
for _, chord in ipairs({
  { "<M-p>", "<leader><space>", "Find Files (Root Dir)" }, -- Cmd+P
  { "<M-e>", "<leader>e", "Explorer Snacks (root dir)" }, -- Cmd+B
  { "<M-:>", "<leader>sC", "Commands" }, -- Cmd+Shift+P
  { "<M-S-;>", "<leader>sC", "Commands" },
  { "<M-w>", "<leader>bd", "Delete Buffer" }, -- Cmd+W
  { "<M-.>", "<leader>ca", "Code Action" }, -- Cmd+.
  { "<M-S-f>", "<leader>sg", "Grep (Root Dir)" }, -- Cmd+Shift+F
  { "<M-S-h>", "<leader>sr", "Search and Replace" }, -- Cmd+Shift+H
  { "<M-o>", "<leader>ss", "LSP Symbols" }, -- Cmd+Shift+O
  { "<M-`>", "<c-/>", "Terminal (Root Dir)" }, -- Ctrl+`
}) do
  map("n", chord[1], chord[2], { remap = true, desc = chord[3] })
  map("i", chord[1], "<Esc>" .. chord[2], { remap = true, desc = chord[3] })
end
map("t", "<M-`>", "<c-/>", { remap = true, desc = "Hide Terminal" })
map("x", "<M-.>", "<leader>ca", { remap = true, desc = "Code Action" })
map("x", "<M-S-h>", "<leader>sr", { remap = true, desc = "Search and Replace" })
map({ "n", "i", "x" }, "<M-s>", "<C-s>", { remap = true, desc = "Save File" }) -- Cmd+S
map("n", "<M-/>", "gcc", { remap = true, desc = "Toggle Comment" }) -- Cmd+/
map("i", "<M-/>", "<Esc>gcc", { remap = true, desc = "Toggle Comment" })
map("x", "<M-/>", "gc", { remap = true, desc = "Toggle Comment" })
for n = 1, 9 do -- Cmd+1..9
  map({ "n", "i" }, "<M-" .. n .. ">", "<cmd>BufferLineGoToBuffer " .. n .. "<cr><esc>", { desc = "Buffer " .. n })
end
