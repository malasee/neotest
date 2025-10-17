local M = {}

local ns_name = "neotest_output_links"

local function get_namespace()
  if not M._ns then
    M._ns = vim.api.nvim_create_namespace(ns_name)
  end
  return M._ns
end

local function strip_ansi_with_map(s)
  local esc = string.char(27)
  local i, vis = 1, 0
  local vis_to_raw = {}
  while i <= #s do
    if s:byte(i) == 27 and s:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #s do
        local b = s:byte(j)
        if b and b >= 0x40 and b <= 0x7E then
          j = j + 1
          break
        end
        j = j + 1
      end
      i = j
    else
      vis = vis + 1
      vis_to_raw[vis] = i - 1 -- 0-based raw byte column for this visible char
      i = i + 1
    end
  end
  local clean = s:gsub(esc .. "%[[0-?]*[ -/]*[@-~]", "")
  return clean, vis_to_raw
end

local function add_mark(buf, sr, sc, er, ec, meta)
  local ns = get_namespace()
  local id = vim.api.nvim_buf_set_extmark(buf, ns, sr, sc, {
    end_row = er,
    end_col = ec,
    hl_group = "NeotestOutputLink",
  })
  M._id_to_meta = M._id_to_meta or {}
  M._id_to_meta[id] = meta
end

local function build_concat_maps(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  local vis_lines, maps, cum = {}, {}, {}
  local acc = 0
  for row = 0, total - 1 do
    local raw = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local text, v2r = strip_ansi_with_map(raw)
    vis_lines[row + 1] = text
    maps[row + 1] = v2r
    cum[row + 1] = acc
    acc = acc + #text
  end
  return vis_lines, maps, cum
end

local function map_span_to_buf(buf, vis_lines, maps, cum, start_vis0, end_vis0)
  local total = #vis_lines
  local start_vis = start_vis0
  local end_vis = end_vis0
  local sr = 0
  for i = 1, #cum do
    if cum[i] + #vis_lines[i] > start_vis then
      sr = i - 1
      break
    end
  end
  if sr < 0 then
    sr = 0
  end
  local sc_vis = start_vis - cum[sr + 1] + 1
  local sc = (maps[sr + 1][sc_vis] or 0)
  local er = sr
  while er + 1 <= total - 1 and cum[er + 2] < end_vis do
    er = er + 1
  end
  local er_index = er + 1
  local ec_vis = end_vis - cum[er_index]
  if ec_vis < 0 then
    ec_vis = 0
  end
  local ec = (maps[er_index][ec_vis] or 0) + 1
  return sr, sc, er, ec
end

-- raw_links: array of { path=string, line=number }
function M.place_links(buf, win, raw_links)
  local ns = get_namespace()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  M._id_to_meta = {}
  pcall(vim.api.nvim_set_hl, 0, "NeotestOutputLink", { underline = true })

  local vis_lines, maps, cum = build_concat_maps(buf)
  local concat_vis = table.concat(vis_lines, "")

  -- URLs per line (simple underline)
  for row = 0, #vis_lines - 1 do
    local text, v2r = vis_lines[row + 1], maps[row + 1]
    local s, e = 1, 0
    while true do
      s, e = text:find("https?://%S+", e + 1)
      if not s then
        break
      end
      local sc = v2r[s] or 0
      local ec = (v2r[e] or sc) + 1
      add_mark(buf, row, sc, row, ec, { type = "url", url = text:sub(s, e) })
    end
  end

  if not raw_links or #raw_links == 0 then
    return
  end

  for _, link in ipairs(raw_links) do
    local path = link.path
    local line_no = tonumber(link.line)
    local idx = 1
    while true do
      local s = string.find(concat_vis, path, idx, true)
      if not s then
        break
      end
      local e = s + #path
      local suffix = concat_vis:sub(e, e + 24)
      local ok_suffix = false
      if suffix:match("^%s*:line%s*" .. line_no) or suffix:match("^:%s*" .. line_no) then
        ok_suffix = true
      end
      if ok_suffix then
        local sr, sc, er, ec = map_span_to_buf(buf, vis_lines, maps, cum, s - 1, e - 1)
        add_mark(buf, sr, sc, er, ec, { type = "path", path = path, line = line_no })
      end
      idx = e
    end
  end
end

function M.meta_under_cursor(buf, win)
  local ns = get_namespace()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]
  local start_row = math.max(0, row - 1)
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    ns,
    { start_row, 0 },
    { row + 1, -1 },
    { details = true }
  )
  local best, best_dist
  for _, mark in ipairs(marks) do
    local id, mr, mc, details = mark[1], mark[2], mark[3], mark[4]
    local er = details.end_row or mr
    local ec = details.end_col or mc
    local within = (row > mr and row < er)
      or (row == mr and col >= mc and (er > mr or col <= ec))
      or (row == er and col <= ec)
    if within then
      local meta = M._id_to_meta and M._id_to_meta[id]
      if meta then
        local dist = (row == mr) and math.abs(col - mc) or math.huge
        if not best or dist < best_dist then
          best, best_dist = meta, dist
        end
      end
    end
  end
  return best or nil
end

function M.setup_keymaps(buf, win, opts)
  local function open_meta(meta)
    if not meta then
      return
    end
    if meta.type == "url" then
      local url = meta.url
      if vim.ui and vim.ui.open then
        pcall(vim.ui.open, url)
      else
        local opener = vim.fn.has("mac") == 1 and "open"
          or (vim.fn.executable("xdg-open") == 1 and "xdg-open" or nil)
        if opener then
          pcall(vim.fn.jobstart, { opener, url }, { detach = true })
        end
      end
      return
    end
    if meta.type == "path" then
      local path = meta.path
      local lnum = meta.line or 1
      local stat_ok, stat = pcall(vim.loop.fs_stat, path)
      if stat_ok and stat then
        local edit_cmd = (opts and opts.open_in) or "tabedit"
        vim.cmd(edit_cmd .. " " .. vim.fn.fnameescape(path))
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
      else
        pcall(vim.notify, "File not found: " .. tostring(path), vim.log.levels.WARN)
      end
    end
  end

  local function open_under_cursor()
    local meta = M.meta_under_cursor(buf, win)
    if not meta then
      pcall(vim.notify, "No link under cursor", vim.log.levels.INFO)
      return
    end
    open_meta(meta)
  end

  pcall(
    vim.keymap.set,
    "n",
    "<CR>",
    open_under_cursor,
    { buffer = buf, nowait = true, silent = true }
  )
  pcall(
    vim.keymap.set,
    "n",
    "gf",
    open_under_cursor,
    { buffer = buf, nowait = true, silent = true }
  )
  pcall(vim.keymap.set, "n", "gx", function()
    local meta = M.meta_under_cursor(buf, win)
    if not meta or meta.type ~= "url" then
      pcall(vim.notify, "No URL under cursor", vim.log.levels.INFO)
      return
    end
    open_meta(meta)
  end, { buffer = buf, nowait = true, silent = true })
end

function M.attach_autocmds(buf, win, raw_links)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    buffer = buf,
    callback = function()
      pcall(M.place_links, buf, win, raw_links)
    end,
  })
end

-- Extracts full file paths with optional ':line N' or ':N' suffixes from raw text
-- Returns array of { path=string, line=number }
function M.extract_links_from_text(text)
  if not text or type(text) ~= "string" then
    return {}
  end
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out = {}
  for p, l in normalized:gmatch("(/[%w%._%-%/]+%.[%w]+)%s*:line%s*(%d+)") do
    table.insert(out, { path = p, line = tonumber(l) })
  end
  for p, l in normalized:gmatch("(/[%w%._%-%/]+%.[%w]+):(%d+)") do
    table.insert(out, { path = p, line = tonumber(l) })
  end
  return out
end

return M
