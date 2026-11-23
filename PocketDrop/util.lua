-- util.lua
-- Small helpers used everywhere: paths, files, logging, settings and the
-- sites.ini reader. Uses plain Lua io/os so it can write next to the app
-- (love.filesystem can only write inside LOVE's private save folder).

local U = {}

U.isWindows = package.config:sub(1, 1) == "\\"

-- Wrap a path or URL in quotes so the shell treats it as one safe argument.
function U.quote(s)
  s = tostring(s)
  if U.isWindows then
    return '"' .. (s:gsub('"', '')) .. '"'
  end
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- True if a file or folder exists.
function U.exists(path)
  local ok = os.rename(path, path)
  if ok then return true end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Create a folder (and any missing parent folders).
function U.mkdir(path)
  if U.exists(path) then return true end
  if U.isWindows then
    os.execute('mkdir ' .. U.quote((path:gsub("/", "\\"))) .. ' >nul 2>nul')
  else
    os.execute('mkdir -p ' .. U.quote(path) .. ' >/dev/null 2>&1')
  end
  return U.exists(path)
end

function U.readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  -- Windows Notepad may add an invisible "BOM" at the start; drop it.
  return (data:gsub("^\239\187\191", ""))
end

function U.writeFile(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

function U.appendFile(path, data)
  local f = io.open(path, "ab")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

-- Size of a file in bytes (0 if missing).
function U.fileSize(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size
end

function U.trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- Make a downloaded file name safe to save on the SD card.
function U.safeName(name)
  name = name:gsub("[/\\:*?\"<>|%c]", "_")
  name = name:gsub("^%.+", "")
  if name == "" then name = "download" end
  return name
end

function U.formatBytes(n)
  if not n or n <= 0 then return "?" end
  if n >= 1024 * 1024 * 1024 then return string.format("%.2f GB", n / 1073741824) end
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1048576) end
  if n >= 1024 then return string.format("%.0f KB", n / 1024) end
  return n .. " B"
end

---------------------------------------------------------------- logging
U.logPath = nil

function U.startLog(path, header)
  U.logPath = path
  -- keep the previous session's log, so a problem isn't lost by restarting
  local prev = path:gsub("%.txt$", "") .. "-previous.txt"
  os.remove(prev)
  os.rename(path, prev)
  U.writeFile(path, header .. "\n")
end

-- Hide API keys so log.txt is safe to share.
function U.mask(s)
  return (tostring(s):gsub("([?&]key=)[^&'\"%s]+", "%1***"):gsub("(api_key%s*=%s*)%S+", "%1***"))
end

function U.log(msg)
  msg = U.mask(msg)
  print(msg)
  if U.logPath then
    U.appendFile(U.logPath, os.date("%H:%M:%S ") .. tostring(msg) .. "\n")
  end
end

---------------------------------------------------------------- settings
-- settings.txt holds simple "key = value" lines.
function U.loadSettings(path, defaults)
  local s = {}
  for k, v in pairs(defaults) do s[k] = v end
  local text = U.readFile(path)
  if text then
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k then
        if v == "true" then v = true elseif v == "false" then v = false end
        s[k] = v
      end
    end
  end
  return s
end

function U.saveSettings(path, s)
  local keys = {}
  for k in pairs(s) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. " = " .. tostring(s[k]) end
  U.writeFile(path, table.concat(out, "\n") .. "\n")
end

---------------------------------------------------------------- sites.ini
-- Each [Section] is a category (e.g. Game Boy Advance).
--   folder = GBA                         -> saves into ROMS/GBA
--   unzip  = yes / no                    -> unpack .zip after download
--   source = Name | https://folder/url/  -> one line per source (repeatable)
-- Returns the categories plus extras (extras.gdrive_key = your Google API key).
function U.parseSites(text)
  local cats, cur, n = {}, nil, 0
  local extras = {}
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    local t = U.trim(line)
    local first = t:sub(1, 1)
    if t == "" or first == ";" or first == "#" then
      -- blank line or comment
    elseif t:match("^%[.+%]$") then
      local name = U.trim(t:sub(2, -2))
      cur = { name = name, folder = name, unzip = nil, sources = {} }
      cats[#cats + 1] = cur
    else
      local k, v = t:match("^([%w_]+)%s*=%s*(.-)$")
      if not (k and cur) then
        U.log("sites.ini line " .. n .. " ignored: " .. t)
      else
        k = k:lower()
        if k == "source" or k == "url" then
          local name, url = v:match("^(.-)%s*|%s*(%S+)$")
          if not url then name, url = cur.name, v end
          local G = require("gdrive")
          local driveId = G.folderId(url)
          if driveId then
            cur.sources[#cur.sources + 1] = { name = (name ~= "" and name or "Google Drive"), url = "gdrive:" .. driveId }
          elseif url:match("^https?://") then
            -- Internet Archive: accept item pages (/details/...) and _files.xml links too.
            url = url:gsub("^(https?://archive%.org/)details/", "%1download/")
            url = url:match("^(https?://archive%.org/download/[^/]+/)[^/]*_files%.xml$") or url
            if not url:match("/$") then url = url .. "/" end
            if name == "" then name = url end
            cur.sources[#cur.sources + 1] = { name = name, url = url }
          else
            U.log("sites.ini line " .. n .. ": address must start with http:// or https://")
          end
        elseif k == "api_key" or k == "google_api_key" then
          extras.gdrive_key = v
          cur.settingsOnly = true
        elseif k == "library" then
          -- a shared Drive folder whose subfolders become categories
          extras.gdrive_library = require("gdrive").parseInput(v)
          if not extras.gdrive_library then U.log("sites.ini line " .. n .. ": library is not a Drive folder link") end
          cur.settingsOnly = true
        elseif k == "folder" then
          cur.folder = v
        elseif k == "unzip" then
          v = v:lower()
          cur.unzip = (v == "yes" or v == "true" or v == "1")
        else
          U.log("sites.ini line " .. n .. ": unknown setting '" .. k .. "'")
        end
      end
    end
  end
  -- A section that only holds settings (e.g. [Google Drive] api_key = ...)
  -- is not shown as a category.
  local shown = {}
  for _, c in ipairs(cats) do
    if not ((c.settingsOnly or c.name:lower() == "google drive") and #c.sources == 0) then shown[#shown + 1] = c end
  end
  return shown, extras
end

---------------------------------------------------------------- editing sites.ini
-- Small text edits so the setup wizard can save into sites.ini while keeping
-- your comments and other lines exactly as they are.

local function splitLines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("\r$", "")) end
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

-- Find "[name]" (any case). Returns its line number and the last line of the section.
local function findSection(lines, name)
  local start
  for i, l in ipairs(lines) do
    local sec = l:match("^%s*%[(.-)%]%s*$")
    if sec then
      if start then
        local last = i - 1
        while last > start and U.trim(lines[last]) == "" do last = last - 1 end
        return start, last
      end
      if U.trim(sec):lower() == name:lower() then start = i end
    end
  end
  if start then
    local last = #lines
    while last > start and U.trim(lines[last]) == "" do last = last - 1 end
    return start, last
  end
  return nil
end

-- Set "key = value" inside [section]; replaces an existing (or ";"-commented)
-- line for that key, otherwise adds it. Creates the section at the top if missing.
function U.iniSet(text, section, key, value)
  local lines = splitLines(text)
  local s, e = findSection(lines, section)
  local newLine = key .. " = " .. value
  if not s then
    -- put the new section before the first category
    local at = #lines + 1
    for i, l in ipairs(lines) do if l:match("^%s*%[") then at = i break end end
    table.insert(lines, at, "")
    table.insert(lines, at, newLine)
    table.insert(lines, at, "[" .. section .. "]")
    return table.concat(lines, "\n") .. "\n"
  end
  for i = s + 1, e do
    local k = lines[i]:match("^%s*;?%s*([%w_]+)%s*=")
    if k and k:lower() == key:lower() then
      lines[i] = newLine
      return table.concat(lines, "\n") .. "\n"
    end
  end
  table.insert(lines, s + 1, newLine)
  return table.concat(lines, "\n") .. "\n"
end

-- Add a line at the end of [section] (creating the section if needed).
function U.iniAppend(text, section, line, folder)
  local lines = splitLines(text)
  local s, e = findSection(lines, section)
  if not s then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[" .. section .. "]"
    if folder then lines[#lines + 1] = "folder = " .. folder end
    lines[#lines + 1] = line
  else
    table.insert(lines, e + 1, line)
  end
  return table.concat(lines, "\n") .. "\n"
end

function U.iniHasSection(text, section)
  return findSection(splitLines(text), section) ~= nil
end

-- Remove "source = ..." lines in [section] that contain `needle` (plain text).
function U.iniRemoveSources(text, section, needle)
  local lines = splitLines(text)
  local s, e = findSection(lines, section)
  if not s then return text end
  for i = e, s + 1, -1 do
    if lines[i]:match("^%s*source%s*=") and lines[i]:find(needle, 1, true) then table.remove(lines, i) end
  end
  return table.concat(lines, "\n") .. "\n"
end

---------------------------------------------------------------- drive_links.ini
-- The easy file to fill in on a PC: your API key and one Drive folder link
-- per console. Keys are the consoles' short names (NES, SNES, GBA, ...).

function U.linksTemplate(consoles, key, links)
  links = links or {}
  local out = {
    "; ==============================================================",
    ";  Pocket Drop - Google Drive links",
    "; ==============================================================",
    ";  Fill this in on your PC, save it, then copy the PocketDrop folder",
    ";  to your console (or press Y on the app's home screen).",
    ";",
    ";  1. Paste your Google API key after  api_key =",
    ";  2. For each console, paste the share link of its Google Drive",
    ";     folder after the  =  sign. Leave it empty if you don't use it.",
    ";     (Drive: right-click the folder -> Share -> General access:",
    ";      'Anyone with the link' (Viewer) -> Copy link)",
    ";",
    ";  Only use files you have the right to use.",
    ";  Keep this file private: it contains your key and links.",
    "; ==============================================================",
    "",
    "api_key = " .. (key or ""),
    "",
  }
  for _, c in ipairs(consoles) do
    out[#out + 1] = "; " .. c.name .. "  ->  saves to ROMS/" .. c.folder
    out[#out + 1] = c.short .. " = " .. (links[c.short:lower()] or "")
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

-- Returns key, links (short name in lower case -> text after "=").
function U.parseLinks(text)
  local key, links = nil, {}
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local t = U.trim(line)
    if t ~= "" and t:sub(1, 1) ~= ";" and t:sub(1, 1) ~= "#" then
      local k, v = t:match("^([%w_]+)%s*=%s*(.-)$")
      if k then
        if k:lower() == "api_key" then key = (v ~= "" and v or nil)
        elseif v ~= "" then links[k:lower()] = v end
      end
    end
  end
  return key, links
end

-- Set "name = value" (case doesn't matter); adds the line if it's missing.
function U.linksSet(text, name, value)
  local lines = splitLines(text)
  for i, l in ipairs(lines) do
    local k = l:match("^%s*([%w_]+)%s*=")
    if k and k:lower() == name:lower() then
      lines[i] = k .. " = " .. value
      return table.concat(lines, "\n") .. "\n"
    end
  end
  lines[#lines + 1] = name .. " = " .. value
  return table.concat(lines, "\n") .. "\n"
end

U.DEFAULT_SITES = [[
; Pocket Drop settings
; The consoles (NES -> PSP) are built into the app. Link each one to a
; Google Drive folder from the app: highlight a console and press X.
; The app writes those links below as [Console name] sections.
;
; You can also add other sources yourself, e.g.
;   [Game Boy Advance]
;   source = Display name | https://address-of-a-folder-listing/
;
; Only use sources you have the right to download from
; (homebrew, public domain, or your own backups).

[Google Drive]
; Your Google API key (the app can set this for you):
; api_key = PASTE-YOUR-KEY-HERE
]]

return U
