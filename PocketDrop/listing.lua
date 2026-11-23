-- listing.lua
-- Reads a web folder page (an "Index of /" style listing) and turns the
-- links on it into a list of folders and files we can show on screen.

local L = {}

local function decodeEntities(s)
  s = s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'")
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">")
  s = s:gsub("&#x(%x+);", function(h)
    local n = tonumber(h, 16); return n < 128 and string.char(n) or nil end)
  s = s:gsub("&#(%d+);", function(d)
    local n = tonumber(d); return n < 128 and string.char(n) or nil end)
  s = s:gsub("&amp;", "&")
  return s
end

-- "Super%20Game.gba" -> "Super Game.gba"
function L.urlDecode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Turn a link on the page into a full address.
function L.resolve(base, href)
  if href:match("^https?://") then return href end
  local scheme = base:match("^(https?:)")
  if href:sub(1, 2) == "//" then return scheme .. href end
  local origin, path = base:match("^(https?://[^/]+)(.*)$")
  if not origin then return nil end
  if href:sub(1, 1) == "/" then return origin .. href end
  local dir = path:match("^(.*/)") or "/"
  return origin .. dir .. href
end

-- Returns a sorted list of { name, url, dir } for the direct children of base.
-- base must end with "/".
function L.parse(html, base, showHidden)
  local items, seen = {}, {}
  for tag in html:gmatch("<[aA]%s[^>]*>") do
    local href = tag:match('[hH][rR][eE][fF]%s*=%s*"([^"]*)"')
      or tag:match("[hH][rR][eE][fF]%s*=%s*'([^']*)'")
      or tag:match("[hH][rR][eE][fF]%s*=%s*([^%s>]+)")
    if href then
      href = decodeEntities(href)
      href = href:gsub("#.*$", "")
      local skip = href == "" or href:find("?", 1, true)
        or href:match("^%a+:") and not href:match("^https?:")
        or href:match("^%.%./?") or href == "./"
      if not skip then
        href = href:gsub("^%./", "")
        local full = L.resolve(base, href)
        -- Compare paths only, not the server name: some sites (e.g. Internet
        -- Archive) send the page from a different server than the one asked.
        local basePath = base:match("^https?://[^/]+(/.*)$") or "/"
        local fullPath = full and full:match("^https?://[^/]+(/.*)$")
        if fullPath and #fullPath > #basePath and fullPath:sub(1, #basePath) == basePath then
          local rel = fullPath:sub(#basePath + 1)
          local isDir = rel:sub(-1) == "/"
          local core = isDir and rel:sub(1, -2) or rel
          if core ~= "" and not core:find("/", 1, true) and not seen[full] then
            seen[full] = true
            local name = L.urlDecode(core)
            if showHidden or name:sub(1, 1) ~= "." then
              items[#items + 1] = { name = name, url = full, dir = isDir }
            end
          end
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return items
end

---------------------------------------------------------------- Internet Archive
-- Every archive.org item has a file called <item>_files.xml that lists all its
-- files with their sizes. Reading it is more reliable than the web page.

-- "https://archive.org/download/<item>/<folder>/" -> item, "<folder>/"
function L.archiveItem(url)
  local id, rest = url:match("^https?://archive%.org/download/([^/]+)/(.*)$")
  if not id then return nil end
  return id, L.urlDecode(rest)
end

function L.archiveXmlUrl(id)
  return "https://archive.org/download/" .. id .. "/" .. id .. "_files.xml"
end

-- Encode a file name for a web address, keeping "/" between folders.
local function encodePath(s)
  return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Read <item>_files.xml into { {name = "folder/file.gba", size = 1234}, ... }.
-- Keeps only files the uploader added ("original"), not ones archive.org made.
function L.parseArchiveFiles(xml)
  local files = {}
  for attrs, body in xml:gmatch("<file%s([^>]-)>(.-)</file>") do
    local name = attrs:match('name="([^"]*)"')
    local source = attrs:match('source="([^"]*)"')
    local format = body:match("<format>(.-)</format>") or ""
    if name and source == "original" and format ~= "Metadata" and format ~= "Item Tile" then
      files[#files + 1] = { name = decodeEntities(name), size = tonumber(body:match("<size>(%d+)</size>")),
        md5 = body:match("<md5>(%x+)</md5>") }
    end
  end
  return files
end

-- The folders and files directly inside "prefix" ("" = top of the item).
function L.archiveChildren(files, id, prefix, showHidden)
  local base = "https://archive.org/download/" .. id .. "/"
  local items, dirs = {}, {}
  for _, f in ipairs(files) do
    if f.name:sub(1, #prefix) == prefix then
      local rel = f.name:sub(#prefix + 1)
      local slash = rel:find("/", 1, true)
      local name = slash and rel:sub(1, slash - 1) or rel
      if name ~= "" and (showHidden or name:sub(1, 1) ~= ".") then
        if slash then
          if not dirs[name] then
            dirs[name] = { name = name, dir = true, url = base .. encodePath(prefix .. name) .. "/", count = 0, size = 0 }
            items[#items + 1] = dirs[name]
          end
          dirs[name].count = dirs[name].count + 1
          dirs[name].size = dirs[name].size + (f.size or 0)
        else
          items[#items + 1] = { name = name, dir = false, url = base .. encodePath(f.name), size = f.size, md5 = f.md5 }
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return items
end

return L
