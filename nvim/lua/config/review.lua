-- Claude Code's PreToolUse hook (claude/hooks/review.py) calls M.propose before an edit lands:
-- the change is drawn over the buffer with extmarks, the text is untouched, and the answer is written to
-- `result` for the hook to read. Claude Code itself writes the file on accept.
-- Each hunk has a header line with its counter and key hints; when every hunk is decided the review ends,
-- and the hook sends the accepted ones back as the edit to run. A Bash command's changes come the same way
-- after it ran (M.propose with an old file).
-- `<leader>ae` revises the proposal with a side chat: Sonnet answers with edits to `newfile` and the diff is
-- redrawn. config.ask reuses all of this through M.open for a change the user asks for (no hook involved).
local M = {}
local ns = vim.api.nvim_create_namespace("review")
local MODEL = "claude-sonnet-5-5"
local KEYS = { "ga", "gr", "]c", "[c", "<leader>ay", "<leader>an", "<leader>au", "<leader>ai", "<leader>ae" }
local SYSTEM = "You revise a proposed code edit. Reply with at most two sentences, then one or more "
  .. "<edit><old>text copied exactly from the proposed file</old><new>replacement</new></edit> blocks that "
  .. "turn the proposed file into the one the user wants. Each <old> occurs exactly once; put no extra "
  .. "newline after <old> or <new>. Never return the whole file."
-- buf -> { answer = function(line) called with "accept" or "reject ..." when the review ends, newfile,
-- saved = { lhs = buffer-local map we shadow }, win/prev = window we took over and what it showed,
-- created = the buffer did not exist before the review, log = lines of the float,
-- msgs = the chat sent to the API, float = its window, busy = a request is out,
-- within = { from, to } the bytes of newfile the chat may change (nil: all of it),
-- old/new/eol/hunks = the diff last drawn, cur = the hunk in focus, state = { [hunk] = "accepted" | "rejected" } }
local pending = {}

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function spit(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

-- Anything but an accept hands the window back and wipes a buffer the review made, so no stray [No Name].
local function clear(buf, accepted)
  local p = pending[buf]
  if not p then
    return
  end
  pending[buf] = nil
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if p.landed then -- the buffer holds the old text: read what is on disk now, and do not keep a deleted file on screen
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! edit!")
    end)
    accepted = accepted and vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  end
  if p.float and vim.api.nvim_win_is_valid(p.float) then
    vim.api.nvim_win_close(p.float, true)
  end
  if not accepted then
    if p.prev and vim.api.nvim_win_is_valid(p.win) and vim.api.nvim_win_get_buf(p.win) == buf then
      vim.api.nvim_win_set_buf(p.win, p.prev)
    end
    if p.created and vim.fn.bufwinid(buf) == -1 then
      vim.api.nvim_buf_delete(buf, { force = true })
      return
    end
  end
  for _, lhs in ipairs(KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    if p.saved[lhs] then
      vim.api.nvim_buf_call(buf, function()
        vim.fn.mapset("n", false, p.saved[lhs])
      end)
    end
  end
end

local function decide(buf, line)
  local p = pending[buf]
  p.answer(line)
  clear(buf, line == "accept")
end

-- The header above hunk n, as virt_lines chunks: the counter, then each key with what it does. The whole-edit
-- keys sit on the first hunk's header only.
local function header(p, n)
  local chunks = {}
  local function add(text, hl)
    chunks[#chunks + 1] = { text, hl }
  end
  local function key(lhs, label)
    add(" " .. lhs:gsub("<leader>", vim.g.mapleader == " " and "␣" or vim.g.mapleader or "\\"), "Special")
    add(" " .. label .. " ", "Comment")
  end
  local state = p.state[n]
  add(n == p.cur and " ▶ " or "   ", "Comment")
  add(("%d/%d"):format(n, #p.hunks), "Title")
  if state then
    add(state == "accepted" and " ✓ accepted " or " ✗ rejected ", "Comment")
    key("<leader>au", "undo")
  else
    add("  ", "Comment")
    key("]c", "next")
    key("[c", "prev")
    key("<leader>ay", "accept")
    key("<leader>an", "reject")
  end
  if n == 1 then
    add(" │", "Comment")
    key("ga", "accept rest")
    key("gr", "reject all")
    key("<leader>ae", "revise")
    key("<leader>ai", "why")
  end
  return chunks
end

-- Draws the diff of the buffer against `newfile`: a header and a sign per hunk (the one in focus marked),
-- rejected hunks dimmed. The hunk in focus is placed near the top, so its added lines below it stay on screen.
local function render(buf, p)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local old, new = vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.fn.readfile(p.newfile)
  if #old == 1 and old[1] == "" then
    old = {} -- an empty or new file, so its one blank line is not a removed line
  end
  local function text(lines)
    return #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
  end
  p.old, p.new, p.eol = old, new, slurp(p.newfile):sub(-1) == "\n"
  p.hunks = vim.text.diff(text(old), text(new), { result_type = "indices" })
  p.cur = math.min(p.cur, math.max(#p.hunks, 1))
  for n, h in ipairs(p.hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local rejected = p.state[n] == "rejected"
    local head = header(p, n)
    local virt = {}
    for i = sb, sb + cb - 1 do
      virt[#virt + 1] = { { new[i], rejected and "Comment" or "DiffAdd" } }
    end
    if ca > 0 then
      if not rejected then
        for row = sa - 1, sa + ca - 2 do
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "DiffDelete" })
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, sa - 1, 0, { virt_lines = { head }, virt_lines_above = true })
      if cb > 0 then -- the added lines go below the last removed one
        vim.api.nvim_buf_set_extmark(buf, ns, sa + ca - 2, 0, { virt_lines = virt })
      end
    else -- a pure insertion, after line sa: the header leads the added lines
      table.insert(virt, 1, head)
      -- above line 1 is not drawn in an empty buffer, so a new file's lines go under its blank line
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        math.max(sa - 1, 0),
        0,
        { virt_lines = virt, virt_lines_above = sa == 0 and #old > 0 }
      )
    end
    local state = p.state[n]
    vim.api.nvim_buf_set_extmark(buf, ns, math.max(sa - 1, 0), 0, {
      sign_text = state == "accepted" and "✓" or state == "rejected" and "✗" or n == p.cur and "▶" or "▎",
      sign_hl_group = rejected and "Comment" or n == p.cur and "DiffAdd" or "DiffChange",
    })
  end
  local focus = p.hunks[p.cur]
  local row = focus and math.min(math.max(focus[1], 1), math.max(#old, 1))
  -- not p.win: the window the review started in may be closed by now
  local win = vim.api.nvim_get_current_buf() == buf and 0 or vim.fn.bufwinid(buf)
  if row and win ~= -1 then
    vim.api.nvim_win_call(win, function()
      -- topfill: a header above line 1 is filler, hidden unless the window scrolls into it
      local fill = row <= 3 and vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 0 }).fill or 0
      vim.fn.winrestview({ lnum = row, col = 0, topline = math.max(row - 3, 1), topfill = fill })
    end)
  end
end

-- Opens the float, or refreshes it, with the reason for the change and the chat so far.
local function show(buf)
  local p = pending[buf]
  if not (p.float and vim.api.nvim_win_is_valid(p.float)) then
    p.float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      anchor = "SE",
      row = vim.o.lines - 2,
      col = vim.o.columns - 1,
      width = math.min(72, vim.o.columns - 4),
      height = 12,
      style = "minimal",
      border = "rounded",
      title = " Edit ",
    })
    vim.bo[vim.api.nvim_win_get_buf(p.float)].bufhidden = "wipe"
    vim.wo[p.float].wrap = true
  end
  local lines = vim.split(table.concat(p.log, "\n"), "\n")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(p.float), 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(p.float, { #lines, 0 })
end

-- Applies the <edit> blocks of `answer` to `p.newfile`, each <old> found exactly once (inside p.within when
-- set, which then moves with the text). Returns the number applied, or nil and what failed.
local function apply(p, answer)
  local content, n = slurp(p.newfile), 0
  local from, to = p.within and p.within[1] or 1, p.within and p.within[2] or #content
  for old, new in answer:gmatch("<edit>%s*<old>(.-)</old>%s*<new>(.-)</new>%s*</edit>") do
    local s, e = content:find(old, from, true)
    local again = s and content:find(old, e + 1, true)
    if not s or e > to or (again and again + #old - 1 <= to) then
      return nil,
        "not found exactly once" .. (p.within and " in the selection" or "") .. ": " .. vim.trim(old):sub(1, 40)
    end
    content = content:sub(1, s - 1) .. new .. content:sub(e + 1)
    to = to + #new - #old
    n = n + 1
  end
  if n > 0 then
    spit(p.newfile, content)
    if p.within then
      p.within[2] = to
    end
  end
  return n
end

-- One call to the API with the whole chat so far; the key goes to curl on stdin, never into the arguments or
-- the log. on_done(answer) or on_done(nil, what went wrong), always on the main loop.
function M.request(msgs, on_done)
  local key = vim.env.ANTHROPIC_API_KEY
  if not key or key == "" then
    return on_done(nil, "ANTHROPIC_API_KEY is not set")
  end
  local body = vim.fn.tempname()
  vim.fn.writefile({
    vim.json.encode({
      model = MODEL,
      max_tokens = 4096,
      system = SYSTEM,
      messages = msgs,
      output_config = { effort = "low" },
    }),
  }, body)
  local config = table.concat({
    'url = "https://api.anthropic.com/v1/messages"',
    'header = "x-api-key: ' .. key .. '"',
    'header = "anthropic-version: 2023-06-01"',
    'header = "content-type: application/json"',
    'data-binary = "@' .. body .. '"',
  }, "\n")
  vim.system({ "curl", "-sS", "--max-time", "60", "-K", "-" }, { stdin = config, text = true }, function(out)
    vim.schedule(function()
      vim.fn.delete(body)
      local ok, res = pcall(vim.json.decode, out.stdout or "")
      local answer = ""
      for _, block in ipairs(ok and res.content or {}) do
        answer = answer .. (block.type == "text" and block.text or "")
      end
      if answer == "" then
        return on_done(nil, "no answer: " .. ((ok and res.error and res.error.message) or out.stderr or "bad response"))
      end
      on_done(answer)
    end)
  end)
end

-- One round of the side chat.
local function ask(buf, instruction)
  local p = pending[buf]
  local ctx = "Proposed file now:\n<<<\n" .. slurp(p.newfile) .. ">>>\n"
  if #p.msgs == 0 then
    ctx = "File "
      .. vim.api.nvim_buf_get_name(buf)
      .. " on disk:\n<<<\n"
      .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      .. "\n>>>\nClaude's reason for the edit: "
      .. p.why
      .. "\n"
      .. ctx
  end
  if p.within then
    ctx = ctx .. "Only the selected lines may change.\n"
  end
  table.insert(p.msgs, { role = "user", content = ctx .. "Change wanted: " .. instruction })
  table.insert(p.log, "you: " .. instruction)
  table.insert(p.log, "...")
  p.busy = true
  show(buf)
  M.request(p.msgs, function(answer, err)
    if pending[buf] ~= p then
      return
    end
    p.busy = false
    local note = err
    if answer then
      table.insert(p.msgs, { role = "assistant", content = answer })
      local n, failed = apply(p, answer)
      note = vim.trim(answer:gsub("<edit>.-</edit>", ""))
        .. (n and (" [" .. n .. " edits applied]") or (" [" .. failed .. "]"))
      if n and n > 0 then
        p.state, p.cur = {}, 1 -- the hunks changed, so earlier decisions no longer point at anything
        render(buf, p)
      end
    end
    p.log[#p.log] = "Sonnet: " .. note
    show(buf)
  end)
end

-- The proposed text with every rejected hunk left as it is in the buffer.
local function compose(p)
  local out, i = {}, 1 -- i: the next old line to copy
  for n, h in ipairs(p.hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for k = i, ca > 0 and sa - 1 or sa do
      out[#out + 1] = p.old[k]
    end
    local keep = p.state[n] == "rejected"
    for k = keep and sa or sb, keep and sa + ca - 1 or sb + cb - 1 do
      out[#out + 1] = (keep and p.old or p.new)[k]
    end
    i = ca > 0 and sa + ca or sa + 1
  end
  for k = i, #p.old do
    out[#out + 1] = p.old[k]
  end
  return table.concat(out, "\n") .. (p.eol and #out > 0 and "\n" or "")
end

-- Every hunk is decided: send the accepted ones, or a reject when none was accepted.
local function finish(buf)
  local p = pending[buf]
  local accepted, rejected = 0, 0
  for n in ipairs(p.hunks) do
    accepted = accepted + (p.state[n] == "accepted" and 1 or 0)
    rejected = rejected + (p.state[n] == "rejected" and 1 or 0)
  end
  if accepted == 0 then
    return decide(buf, "reject every change was rejected")
  end
  if rejected > 0 then
    spit(p.newfile, compose(p))
  end
  decide(buf, "accept")
end

local function goto_hunk(buf, delta)
  local p = pending[buf]
  if #p.hunks > 0 then
    p.cur = (p.cur - 1 + delta) % #p.hunks + 1
    render(buf, p)
  end
end

-- Decides the hunk in focus, then moves to the next undecided one, or finishes when there is none.
local function decide_hunk(buf, state)
  local p = pending[buf]
  if not p.hunks[p.cur] then
    return
  end
  p.state[p.cur] = state
  for step = 1, #p.hunks do
    local k = (p.cur - 1 + step) % #p.hunks + 1
    if not p.state[k] then
      p.cur = k
      return render(buf, p)
    end
  end
  finish(buf)
end

local function undo_hunk(buf)
  local p = pending[buf]
  p.state[p.cur] = nil
  render(buf, p)
end

-- Takes everything still undecided.
local function accept_rest(buf)
  local p = pending[buf]
  for n in ipairs(p.hunks) do
    p.state[n] = p.state[n] or "accepted"
  end
  finish(buf)
end

local function reject_all(buf)
  vim.ui.input({ prompt = "Reject reason (optional): " }, function(reason)
    if reason and pending[buf] then
      decide(buf, vim.trim("reject " .. reason))
    end
  end)
end

local function toggle_why(buf)
  local p = pending[buf]
  if p.float and vim.api.nvim_win_is_valid(p.float) then
    vim.api.nvim_win_close(p.float, true)
  else
    show(buf)
  end
end

local function revise(buf)
  local p = pending[buf]
  show(buf)
  vim.ui.input({ prompt = "Change this edit: " }, function(text)
    if text and text ~= "" and pending[buf] == p and not p.busy then
      ask(buf, text)
    end
  end)
end

-- Draws the review of p.newfile over `buf` and takes the keys. Returns 1, or 0 when nothing differs.
local function start(buf, p)
  -- Buffer-local and only while pending: they shadow mini.align's `ga`, LazyVim's LSP `gr` and gitsigns'
  -- `]c`/`[c` here, which clear() puts back.
  p.saved = {}
  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(KEYS) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      p.saved[lhs] = m.buffer == 1 and m or nil
    end
  end)
  p.log = p.log or { "Claude: " .. (p.why ~= "" and p.why or "(no reason found)") }
  p.msgs = p.msgs or {}
  p.cur, p.state = 1, {}
  pending[buf] = p
  render(buf, p)
  if #p.hunks == 0 then -- the edit changes nothing, so there is nothing to decide
    clear(buf)
    return 0
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      fn(buf)
    end, { buffer = buf, nowait = true, desc = desc })
  end
  map("ga", accept_rest, "Accept the rest of the edit")
  map("gr", reject_all, "Reject the whole edit")
  map("]c", function(b)
    goto_hunk(b, 1)
  end, "Next hunk of the edit")
  map("[c", function(b)
    goto_hunk(b, -1)
  end, "Previous hunk of the edit")
  map("<leader>ay", function(b)
    decide_hunk(b, "accepted")
  end, "Accept this hunk")
  map("<leader>an", function(b)
    decide_hunk(b, "rejected")
  end, "Reject this hunk")
  map("<leader>au", undo_hunk, "Undo the decision on this hunk")
  map("<leader>ai", toggle_why, "Why the edit was made")
  map("<leader>ae", revise, "Revise the edit")
  vim.notify(
    "Edit: ga accept rest, gr reject all, <leader>ay/<leader>an this hunk, ]c/[c move, <leader>ae revise, <leader>ai why"
  )
  return 1
end

-- The hook allows every edit without a diff while this is on. A plain global, so a restart turns it off.
function M.toggle()
  vim.g.claude_review_auto = not vim.g.claude_review_auto
  vim.notify("Edit review: auto-accept " .. (vim.g.claude_review_auto and "ON" or "off"))
end

M.apply = apply

-- With `oldfile` the change is one a Bash command already made (the hook's PostToolUse half): `newfile` is a copy
-- of the file on disk and `oldfile` its text before the command ("" when it did not exist). The buffer is set back
-- to the old text, so the same diff is drawn, and what the user rejects or revises is written to disk here.
function M.propose(path, newfile, result, why, oldfile)
  local created = vim.fn.bufnr(path) == -1
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  -- a second edit to the file replaces the first on screen, so the first is told, not left to time out unreviewed
  -- (a landed change whose hook is gone stays as the command left it)
  local prior = pending[buf]
  if prior then
    if not prior.landed then
      prior.answer("reject superseded by a newer edit to this file")
    end
    created = prior.created
  end
  clear(buf, true)
  if oldfile and vim.bo[buf].modified then
    return 0 -- unsaved work of the user's, not to be drawn over
  end
  local win, prev = vim.fn.bufwinid(buf), prior and prior.prev
  if win == -1 then
    win = vim.api.nvim_get_current_win()
    prev = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
  end
  local landed = oldfile and slurp(newfile)
  local old = landed and oldfile ~= "" and slurp(oldfile)
  if landed then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, old and vim.fn.readfile(oldfile) or {})
  end
  return start(buf, {
    answer = function(line)
      local final = landed and (line == "accept" and slurp(newfile) or old)
      if final ~= landed then
        if final then
          vim.fn.mkdir(vim.fs.dirname(path), "p")
          spit(path, final)
        else
          os.remove(path)
        end
      end
      vim.fn.writefile({ line }, result)
    end,
    newfile = newfile,
    landed = landed,
    win = win,
    prev = prev,
    created = created,
    why = why,
  })
end

-- The review of a change the user asked for, in the window that shows `buf`. opts: newfile, why, answer,
-- and the chat so far (log, msgs) with the bytes it may change (within). Returns 1, or 0 when nothing differs.
function M.open(buf, opts)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return 0
  end
  return start(buf, vim.tbl_extend("force", { win = win, created = false }, opts))
end

return M
