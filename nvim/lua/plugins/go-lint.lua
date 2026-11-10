-- golangci-lint needs to start inside a Go module. nvim-lint starts it in
-- Neovim's working directory, which in this repo is the root, while the module
-- lives in server/: every import of our own packages then fails with
-- "go.mod file not found". Run it from the buffer's module root instead.
-- (A go.work at the repo root is not the answer: gopls stops loading with it.)
--
-- nvim-lint also decides once, from that same working directory, whether a
-- go.mod exists, and with none it lints the single file instead of its package:
-- every name declared in a sibling file is then "undefined". Inside a module,
-- hand it the package directory.
return {
  "mfussenegger/nvim-lint",
  opts = {
    linters = {
      golangcilint = function()
        local linter = vim.deepcopy(require("lint.linters.golangcilint"))
        local root = vim.fs.root(0, { "go.work", "go.mod" })
        if root then
          linter.cwd = root
          linter.args[#linter.args] = function()
            return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h")
          end
        end
        return linter
      end,
    },
  },
}
