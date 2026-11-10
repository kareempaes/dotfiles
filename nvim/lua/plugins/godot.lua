-- Godot: the GDScript language server is served by the running Godot editor on 127.0.0.1:6005
-- (override with $GDScript_Port), so completion and diagnostics only work while the editor is open.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "gdscript", "godot_resource", "gdshader" } },
  },
  {
    "neovim/nvim-lspconfig",
    -- Not a Mason package: the server is Godot itself.
    opts = { servers = { gdscript = { mason = false } } },
  },
}
