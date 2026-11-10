-- LazyVim binds Option+P per buffer to the previous reference on LSP attach, which would shadow
-- the global Cmd+P stand-in (keymaps.lua); `[[` still does the jump. Option+N keeps the next one.
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = { ["*"] = { keys = { { "<a-p>", false } } } },
  },
}
