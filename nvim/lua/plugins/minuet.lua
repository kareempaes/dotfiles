return {
  "milanglacier/minuet-ai.nvim",
  event = "InsertEnter",
  opts = {
    provider = "claude",
    n_completions = 1, -- one candidate per request
    context_window = 8000,
    request_timeout = 3,
    throttle = 1500,
    debounce = 600,
    provider_options = {
      claude = {
        model = "claude-haiku-4-5",
        max_tokens = 512,
      },
    },
    virtualtext = {
      auto_trigger_ft = {},
      keymap = {
        accept = "<A-A>", -- whole completion
        accept_line = "<A-a>", -- one line
        accept_n_lines = "<A-z>",
        prev = "<A-p>",
        next = "<A-n>",
        dismiss = "<A-e>",
      },
    },
  },
}
