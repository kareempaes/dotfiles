-- The extra loads claudecode.nvim on its first <leader>a key, so until then there is no server
-- and Claude Code's /ide lists nothing. Start it with Neovim instead.
-- Claude Code runs in its own tmux pane, so no terminal inside Neovim: with the default
-- provider every send (<leader>ab, <leader>as) opened one.
-- <leader>ab re-sends the tracked selection (Claude Code shows "N lines selected" or the file),
-- not an @mention typed into the prompt. Claude Code drops it after each message and the plugin
-- only sends on a cursor move, so this brings it back without moving.
return {
  {
    "coder/claudecode.nvim",
    event = "VeryLazy",
    opts = { terminal = { provider = "none" } },
    keys = {
      {
        "<leader>ab",
        function()
          require("claudecode.selection").send_current_selection()
        end,
        mode = { "n", "v" },
        desc = "Send selection to Claude",
      },
      {
        "<leader>ak",
        function()
          local a, b = vim.fn.line("v"), vim.fn.line(".")
          require("config.ask").ask(math.min(a, b), math.max(a, b))
        end,
        mode = { "n", "v" },
        desc = "Ask Sonnet to change the selection",
      },
      {
        "<leader>aA",
        function()
          require("config.review").toggle()
        end,
        desc = "Toggle auto-accept of Claude edits",
      },
    },
  },
  -- lualine badge for the auto-accept toggle above, so it can't stay on unnoticed
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return "review: auto"
        end,
        cond = function()
          return vim.g.claude_review_auto == true
        end,
        color = "DiagnosticWarn",
      })
    end,
  },
}
