-- Tab / Shift-Tab step to the next / previous match while typing a / or ? search, as <C-g> /
-- <C-t> do (:h c_CTRL-G). blink.cmp owns Tab on the command line and would otherwise complete
-- a buffer word. With the completion menu open (<C-space> shows it) Tab cycles the items again,
-- and on the : line it completes as before.
local function search_step(key)
  return function(cmp)
    if not vim.fn.getcmdtype():match("[/?]") or cmp.is_menu_visible() then
      return false
    end
    -- "i": ahead of any keys already typed after Tab, so the jump is not run after <CR>.
    vim.api.nvim_feedkeys(vim.keycode(key), "in", false)
    return true
  end
end

return {
  {
    "saghen/blink.cmp",
    opts = {
      -- Insert mode: Tab accepts the selected item, as in VSCode (<CR> still does too).
      keymap = {
        ["<Tab>"] = { "select_and_accept", "snippet_forward", "fallback" },
      },
      cmdline = {
        keymap = {
          ["<Tab>"] = { search_step("<C-g>"), "show_and_insert_or_accept_single", "select_next" },
          ["<S-Tab>"] = {
            search_step("<C-t>"),
            function(cmp)
              return cmp.show_and_insert_or_accept_single({ initial_selected_item_idx = -1 })
            end,
            "select_prev",
          },
        },
      },
    },
  },
}
