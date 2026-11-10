-- Ask Sonnet to change the selected lines (or the cursor line). The change comes back as a pending diff, the same
-- per-hunk review as for Claude Code's edits, and accepting it puts the new lines in the buffer, unsaved.
local review = require("config.review")
local M = {}
local CONTEXT = 100 -- lines of surrounding code sent on each side of the selection

function M.ask(first, last)
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  vim.ui.input({ prompt = ("Change lines %d-%d: "):format(first, last) }, function(instruction)
    if not instruction or instruction == "" then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local newfile = vim.fn.tempname()
    -- the bytes of the selection in the whole text, which is all the edits may touch
    local from = 1
    for i = 1, first - 1 do
      from = from + #lines[i] + 1
    end
    local selected = table.concat(lines, "\n", first, last)
    local within = { from, from + #selected - 1 }
    vim.fn.writefile(
      vim.split(table.concat(lines, "\n") .. (vim.bo[buf].eol and "\n" or ""), "\n", { plain = true }),
      newfile,
      "b"
    )
    local msgs = {
      {
        role = "user",
        content = "File "
          .. vim.api.nvim_buf_get_name(buf)
          .. ", for context only:\n<<<\n"
          .. table.concat(lines, "\n", math.max(first - CONTEXT, 1), math.min(last + CONTEXT, #lines))
          .. "\n>>>\nThe selected lines, the only text you may change:\n<<<\n"
          .. selected
          .. "\n>>>\nChange wanted: "
          .. instruction,
      },
    }
    review.request(msgs, function(answer, err)
      local function give_up(why)
        vim.fn.delete(newfile)
        vim.notify("Ask: " .. why, vim.log.levels.WARN)
      end
      if not answer then
        return give_up(err)
      elseif vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return give_up("the buffer changed while waiting")
      end
      table.insert(msgs, { role = "assistant", content = answer })
      local n, failed = review.apply({ newfile = newfile, within = within }, answer)
      if not n or n == 0 then
        return give_up(failed or "no change proposed")
      end
      local note = vim.trim(answer:gsub("<edit>.-</edit>", ""))
      local opened = review.open(buf, {
        newfile = newfile,
        within = within,
        msgs = msgs,
        why = instruction,
        log = { "You: " .. instruction, "Sonnet: " .. note },
        answer = function(line)
          if line == "accept" and vim.api.nvim_buf_get_changedtick(buf) == tick then
            local new = vim.fn.readfile(newfile, "b")
            if new[#new] == "" then -- "b" keeps the empty item after a final newline
              table.remove(new)
            end
            -- lines after the selection are unchanged, so the selection is what lies between the same two ends
            vim.api.nvim_buf_set_lines(buf, first - 1, last, false, vim.list_slice(new, first, #new - (#lines - last)))
          elseif line == "accept" then
            vim.notify("Ask: the buffer changed during the review, nothing applied", vim.log.levels.WARN)
          end
          vim.fn.delete(newfile)
        end,
      })
      if opened == 0 then
        give_up("the change is the same as what is there")
      end
    end)
  end)
end

return M
