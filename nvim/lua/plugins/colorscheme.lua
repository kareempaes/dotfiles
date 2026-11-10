return {
  -- Monokai Soda, the closest Neovim match for Ghostty's theme
  {
    "tanvirtin/monokai.nvim",
    priority = 1000,
  },

  -- Configure LazyVim to load it (colors/monokai_soda.vim applies the Soda palette)
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "monokai_soda",
    },
  },
}
