-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua

-- Claude Code writes files straight to disk. The PostToolUse hook calls M.sync(), which reloads every
-- loaded, unmodified buffer whose file changed on disk. A file is read only when its mtime or size
-- moved since the last call, so the hook is cheap when nothing changed.
vim.o.autoread = true

local M = {}
local stamp = {}

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function M.sync()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buf)
    local st = vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and not vim.bo[buf].modified
      and vim.uv.fs_stat(path)
    local sig = st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size)
    if st and sig ~= stamp[buf] then
      stamp[buf] = sig
      if not vim.deep_equal(vim.fn.readfile(path), lines_of(buf)) then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent! edit")
        end)
      end
    end
  end
end

return M
