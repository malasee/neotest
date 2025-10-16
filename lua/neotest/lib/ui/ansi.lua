local M = {}

-- Replace common textual encodings of ESC with actual ESC byte
function M.decode_ansi_escapes(s)
  if not s or type(s) ~= "string" then
    return s
  end
  local esc = string.char(27)
  s = s:gsub("\\x1[bB]", esc)
  s = s:gsub("\\u001[bB]", esc)
  s = s:gsub("\\033", esc)
  s = s:gsub("\\e", esc)
  return s
end

return M
