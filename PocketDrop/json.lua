-- json.lua
-- A small JSON reader (decode only), enough for Google Drive's answers.
-- Turns text like {"files":[{"name":"a.gba"}]} into Lua tables.

local J = {}

local function utf8char(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
  return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function J.decode(text)
  local pos = 1

  local function fail(msg) error("JSON: " .. msg .. " at position " .. pos) end
  local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end

  local value

  local function str()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == "" then fail("unfinished text") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        if e == "u" then
          local n = tonumber(text:sub(pos + 2, pos + 5), 16) or 63
          -- join "surrogate pairs" (emoji etc.) into one character
          if n >= 0xD800 and n <= 0xDBFF and text:sub(pos + 6, pos + 7) == "\\u" then
            local lo = tonumber(text:sub(pos + 8, pos + 11), 16) or 0
            n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
          if n >= 0x10000 then
            out[#out + 1] = string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
              0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
          else
            out[#out + 1] = utf8char(n)
          end
          pos = pos + 6
        else
          out[#out + 1] = escapes[e] or e
          pos = pos + 2
        end
      else
        local stop = text:find('["\\]', pos) or #text + 1
        out[#out + 1] = text:sub(pos, stop - 1)
        pos = stop
      end
    end
    return table.concat(out)
  end

  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then fail("expected a name") end
        local k = str()
        skip()
        if text:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        obj[k] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then fail("unexpected character '" .. c .. "'") end
      pos = pos + #num
      return tonumber(num)
    end
  end

  local ok, result = pcall(value)
  if ok then return result end
  return nil, result
end

return J
