-- main.lua
-- Pocket Drop for muOS (Anbernic RG35XX SP).
-- Pick a category (e.g. Game Boy Advance), pick one of your sources, browse
-- its folders and press A on a file: it downloads straight into the right
-- ROMS folder and unzips it if needed. One click.

local U = require("util")
local L = require("listing")
local G = require("gdrive")
local CONSOLES = require("consoles")

local VERSION = "1.0"
local W, H = 640, 480
local ROWS, ROW_H, LIST_Y = 11, 32, 56

local C = {                       -- colours
  bg = { 0.09, 0.09, 0.11 }, bar = { 0.16, 0.16, 0.20 },
  text = { 0.92, 0.92, 0.92 }, dim = { 0.55, 0.55, 0.60 },
  sel = { 0.95, 0.72, 0.15 }, selText = { 0.08, 0.08, 0.08 },
  ok = { 0.35, 0.85, 0.45 }, bad = { 0.95, 0.40, 0.35 },
}

local app = {
  dir = nil, tmp = nil, sitesPath = nil, settingsPath = nil, historyPath = nil,
  onDevice = false, tool = "curl", cats = {}, settings = {}, romRoots = {},
  iaCache = {},                   -- Internet Archive item -> its file list
  siteCats = {},                  -- categories written in sites.ini
  driveFolders = nil,             -- Drive library subfolders { {name, id}, ... }
  libState = "off",               -- off / loading / ok / cached / error
  libError = nil,
}
local fonts = {}
local stack = {}                  -- open screens, last one is on top
local screens = {}
local popup = nil                 -- { title, text, aLabel, bLabel, onA, onB }
local jobs, results, worker
local nextId = 0
local pending = {}                -- job id -> callback
local held = {}                   -- action -> time pressed
local rep = { act = nil, t = 0 }  -- D-pad auto-repeat
local buttonLog = {}              -- for the button test screen

---------------------------------------------------------------- helpers
local function setColor(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

local function top() return stack[#stack] end

local function push(name, data)
  local s = data or {}
  s.name, s.sel = name, s.sel or 1
  stack[#stack + 1] = s
  if screens[name].enter then screens[name].enter(s) end
end

local function pop()
  if #stack > 1 then table.remove(stack) end
end

local function showPopup(p) popup = p end

local function message(title, text)
  showPopup({ title = title, text = text, aLabel = "OK" })
end

local boostOff

-- Stop any download running in the background (so the app can always close).
local function stopBackground()
  if not app.tmp then return end
  U.writeFile(app.tmp .. "/download.cancel", "stop")
  for pid in (U.readFile(app.tmp .. "/download.pid") or ""):gmatch("%d+") do
    if U.isWindows then os.execute("taskkill /F /IM curl.exe >nul 2>nul")
    else os.execute("kill " .. pid .. " >/dev/null 2>&1") end
  end
end

local function quitApp()
  if boostOff then pcall(boostOff) end
  pcall(stopBackground)
  if jobs then jobs:push({ kind = "quit" }) end
  pcall(U.log, "quitting")
  -- Write everything to the SD card, then close at once: never wait on a
  -- download still finishing in the background (that used to hang the app).
  if not U.isWindows then os.execute("sync") end
  os.exit(0)
  love.event.quit()
end

local function askQuit()
  showPopup({ title = "Quit Pocket Drop?", text = "", aLabel = "Quit", bLabel = "Cancel", onA = quitApp })
end

local function sendJob(job, callback)
  nextId = nextId + 1
  job.id = nextId
  job.tool, job.win, job.tmp = app.tool, U.isWindows, app.tmp
  pending[job.id] = callback
  jobs:push(job)
  return job.id
end

local function errorText(code, err)
  local t = {
    [6] = "Can't find the site. Is Wi-Fi on?",
    [7] = "Couldn't connect to the site.",
    [22] = "The site refused the request (file missing or blocked).",
    [23] = "Couldn't save the file. Is the SD card full?",
    [28] = "The site took too long to answer.",
    [35] = "Secure connection failed. Check the date and time.",
    [60] = "Secure connection failed. Check the date and time.",
    [77] = "Secure connection failed (certificates missing).",
    [127] = "Download tool not found (curl/wget).",
  }
  local s = t[code] or ("Error code " .. tostring(code))
  if code == 22 and err then
    if err:find("401", 1, true) then
      s = "This file needs an archive.org login (the item is access-restricted).\nPocket Drop can only open files that anyone can download."
    elseif err:find("403", 1, true) then
      s = "The site blocked this request (403 Forbidden)."
    elseif err:find("404", 1, true) then
      s = "That file or folder isn't there any more (404)."
    end
  end
  if err and err ~= "" then s = s .. "\n\n" .. err end
  return s
end

local function saveSettings() U.saveSettings(app.settingsPath, app.settings) end

-- A partial download may be split in pieces: "x.part", "x.part.s2" ... "x.part.s8".
local function partialSize(part)
  -- each piece may also have a ".c" file being filled by its connection right now
  local n = U.fileSize(part) + U.fileSize(part .. ".c")
  for i = 2, 8 do n = n + U.fileSize(part .. ".s" .. i) + U.fileSize(part .. ".s" .. i .. ".c") end
  return n
end

local function deletePartial(part)
  os.remove(part); os.remove(part .. ".c")
  for i = 2, 8 do os.remove(part .. ".s" .. i); os.remove(part .. ".s" .. i .. ".c") end
end

---------------------------------------------------------------- speed boost
-- While downloading on the handheld: CPU at full speed (it decrypts the HTTPS
-- data) and Wi-Fi power saving off (the chip naps between packets otherwise).
-- Everything is put back afterwards, also on quit or crash.
local boost = { active = false }

local function readLine(path)
  local t = U.readFile(path)
  return t and U.trim(t) or nil
end

local function boostOn()
  if boost.active or not app.onDevice or app.settings.boost == false then return end
  boost.active = true
  local gpath = "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
  if not U.exists(gpath) then gpath = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" end
  local cur = readLine(gpath)
  if cur and cur ~= "performance" then
    if U.writeFile(gpath, "performance") then boost.gov, boost.govPath = cur, gpath end
  end
  local ls = io.popen("ls /sys/class/net 2>/dev/null")
  local names = ls and ls:read("*a") or ""
  if ls then ls:close() end
  for name in names:gmatch("%S+") do
    if U.exists("/sys/class/net/" .. name .. "/wireless") then
      local p = io.popen("iw dev " .. name .. " get power_save 2>/dev/null")
      local out = p and p:read("*a") or ""
      if p then p:close() end
      if out:lower():find("power save:%s*on") then
        os.execute("iw dev " .. name .. " set power_save off >/dev/null 2>&1")
        boost.wifi, boost.wifiTool = name, "iw"
      elseif out == "" then
        local p2 = io.popen("iwconfig " .. name .. " 2>/dev/null")
        local o2 = p2 and p2:read("*a") or ""
        if p2 then p2:close() end
        if o2:find("Power Management:on") then
          os.execute("iwconfig " .. name .. " power off >/dev/null 2>&1")
          boost.wifi, boost.wifiTool = name, "iwconfig"
        end
      end
    end
  end
  U.log("speed boost on: cpu " .. tostring(boost.gov and "performance (was " .. boost.gov .. ")" or "unchanged")
    .. ", wifi power save " .. tostring(boost.wifi and ("off on " .. boost.wifi) or "unchanged"))
end

boostOff = function()
  if not boost.active then return end
  boost.active = false
  if boost.gov then U.writeFile(boost.govPath, boost.gov) end
  if boost.wifi then
    if boost.wifiTool == "iw" then os.execute("iw dev " .. boost.wifi .. " set power_save on >/dev/null 2>&1")
    else os.execute("iwconfig " .. boost.wifi .. " power on >/dev/null 2>&1") end
  end
  U.log("speed boost off (settings restored)")
  boost.gov, boost.wifi = nil, nil
end

local function romRoot()
  local r = app.settings.roms_root
  if r and r ~= "" and U.exists(r) then return r end
  return app.romRoots[1]
end

local function addHistory(result, cat, name)
  U.appendFile(app.historyPath, os.date("%Y-%m-%d %H:%M") .. " | " .. result .. " | " .. cat .. " | " .. name .. "\n")
end

local function loadSites()
  local text = U.readFile(app.sitesPath)
  if not text then
    U.writeFile(app.sitesPath, U.DEFAULT_SITES)
    text = U.DEFAULT_SITES
    U.log("created sample sites.ini")
  end
  local extras
  app.siteCats, extras = U.parseSites(text)
  app.gdriveKey = extras.gdrive_key
  app.libraryId = extras.gdrive_library
  app.cats = app.siteCats
  U.log("loaded " .. #app.siteCats .. " categories from sites.ini")

  -- drive_links.ini: the easy place for the key and each console's folder link
  local ltext = U.readFile(app.linksPath)
  if not ltext then
    -- first run: start the file with any key/links already in sites.ini
    local found = {}
    for _, con in ipairs(CONSOLES) do
      for _, sec in ipairs(app.siteCats) do
        local n = sec.name:lower()
        if n == con.name:lower() or n == con.short:lower() or n == con.folder:lower() then
          for _, src in ipairs(sec.sources) do
            local id = src.url:match("^gdrive:(.+)$")
            if id then found[con.short:lower()] = "https://drive.google.com/drive/folders/" .. id end
          end
        end
      end
    end
    ltext = U.linksTemplate(CONSOLES, app.gdriveKey, found)
    U.writeFile(app.linksPath, ltext)
    U.log("created drive_links.ini")
  end
  local lkey, links = U.parseLinks(ltext)
  if lkey then app.gdriveKey = lkey end
  app.links = {}
  for short, raw in pairs(links) do
    app.links[short] = { raw = raw, id = G.parseInput(raw) }
    if not app.links[short].id then U.log("drive_links.ini: '" .. short .. "' is not a Drive folder link") end
  end
end

---------------------------------------------------------------- Drive library
-- Every folder inside the shared library folder becomes a category with the
-- same name, saved to ROMS/<folder name>. A category with the same name in
-- sites.ini is merged (its folder/unzip settings win).

local function libraryCachePath() return app.dir .. "/drive_library.txt" end

local function copyCat(c)
  local copy = {}
  for k, v in pairs(c) do copy[k] = v end
  copy.sources = {}
  for _, src in ipairs(c.sources or {}) do copy.sources[#copy.sources + 1] = src end
  return copy
end

-- Does a sites.ini [section] belong to this console? (full name, short name or folder)
local function sectionMatches(section, console)
  local n = section.name:lower()
  return n == console.name:lower() or n == console.short:lower() or n == console.folder:lower()
end

local function mergeLibrary()
  local cats, used = {}, {}
  -- the built-in console list, NES -> PSP
  for _, con in ipairs(CONSOLES) do
    local cat = { name = con.name, short = con.short, folder = con.folder, sources = {}, builtin = true }
    for i, sec in ipairs(app.siteCats) do
      if sectionMatches(sec, con) then
        used[i] = true
        cat.section = sec.name                -- the [section] name used in sites.ini
        if sec.folder and sec.folder ~= sec.name then cat.folder = sec.folder end
        if sec.unzip ~= nil then cat.unzip = sec.unzip end
        for _, src in ipairs(sec.sources) do cat.sources[#cat.sources + 1] = src end
      end
    end
    local link = app.links and app.links[con.short:lower()]
    if link then
      for i = #cat.sources, 1, -1 do
        if cat.sources[i].url:match("^gdrive:") then table.remove(cat.sources, i) end
      end
      if link.id then
        table.insert(cat.sources, 1, { name = "Google Drive", url = "gdrive:" .. link.id })
      else
        cat.badLink = link.raw
      end
    end
    cats[#cats + 1] = cat
  end
  -- any other [sections] you added yourself
  for i, sec in ipairs(app.siteCats) do
    if not used[i] then
      local c = copyCat(sec)
      c.section, c.short = sec.name, sec.name
      cats[#cats + 1] = c
    end
  end
  for _, f in ipairs(app.driveFolders or {}) do
    local src = { name = "Google Drive", url = "gdrive:" .. f.id }
    local found
    for _, c in ipairs(cats) do if c.name:lower() == f.name:lower() then found = c end end
    if found then
      table.insert(found.sources, 1, src)
    else
      cats[#cats + 1] = { name = f.name, folder = U.safeName(f.name), sources = { src }, fromDrive = true }
    end
  end
  app.cats = cats
end

local function saveLibraryCache()
  local out = { "; Pocket Drop - last known Drive library folders (name|id). Safe to delete." }
  for _, f in ipairs(app.driveFolders or {}) do out[#out + 1] = f.name .. "|" .. f.id end
  U.writeFile(libraryCachePath(), table.concat(out, "\n") .. "\n")
end

local function loadLibraryCache()
  local text = U.readFile(libraryCachePath())
  if not text then return false end
  local folders = {}
  for line in text:gmatch("[^\r\n]+") do
    local name, id = line:match("^([^;].-)|([%w_%-]+)$")
    if name then folders[#folders + 1] = { name = name, id = id } end
  end
  app.driveFolders = folders
  return true
end

local function refreshLibrary()
  if not app.libraryId or not app.gdriveKey or app.gdriveKey == "" then
    app.libState, app.driveFolders = "off", nil
    mergeLibrary()
    return
  end
  if app.driveFolders == nil and loadLibraryCache() then app.libState = "cached" end
  mergeLibrary()
  local before = app.libState
  app.libState = "loading"
  local folders = {}
  local function page(token)
    sendJob({ kind = "fetch", url = G.listUrl(app.libraryId, app.gdriveKey, token) }, function(r)
      if r.code ~= 0 then
        app.libState = (before == "cached" or before == "ok") and "cached" or "error"
        app.libError = G.explain(r.code, r.err) or errorText(r.code, r.err)
        U.log("Drive library refresh failed (" .. tostring(r.code) .. "): " .. tostring(r.err))
        return
      end
      local items, nextToken, _, perr = G.parseList(r.body, app.gdriveKey, true)
      if not items then
        app.libState, app.libError = "error", "Couldn't read Google's answer: " .. tostring(perr)
        return
      end
      for _, it in ipairs(items) do
        if it.dir then folders[#folders + 1] = { name = it.name, id = it.url:match("^gdrive:(.+)$") } end
      end
      if nextToken then page(nextToken) return end
      table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
      app.driveFolders, app.libState, app.libError = folders, "ok", nil
      saveLibraryCache()
      mergeLibrary()
      U.log("Drive library: " .. #folders .. " folders")
    end)
  end
  page(nil)
end

local function moveSel(s, delta, count)
  if count == 0 then s.sel = 1 return end
  local old = s.sel
  s.sel = s.sel + delta
  if s.sel < 1 then s.sel = (old == 1 and delta == -1) and count or 1 end
  if s.sel > count then s.sel = (old == count and delta == 1) and 1 or count end
end

---------------------------------------------------------------- drawing
local function drawBar(title, hints)
  setColor(C.bar)
  love.graphics.rectangle("fill", 0, 0, W, 44)
  love.graphics.rectangle("fill", 0, H - 36, W, 36)
  setColor(C.sel)
  love.graphics.setFont(fonts.big)
  love.graphics.printf(title, 14, 8, W - 28, "left")
  setColor(C.dim)
  love.graphics.setFont(fonts.small)
  love.graphics.printf(hints or "", 14, H - 27, W - 28, "left")
end

local function drawList(s, items, label)
  love.graphics.setFont(fonts.main)
  local count = #items
  if count == 0 then return end
  s.scroll = s.scroll or 1
  if s.sel < s.scroll then s.scroll = s.sel end
  if s.sel > s.scroll + ROWS - 1 then s.scroll = s.sel - ROWS + 1 end
  for i = s.scroll, math.min(count, s.scroll + ROWS - 1) do
    local y = LIST_Y + (i - s.scroll) * ROW_H
    local text, color, right = label(items[i], i)
    if i == s.sel then
      setColor(C.sel)
      love.graphics.rectangle("fill", 8, y, W - 16, ROW_H - 4, 4, 4)
      setColor(C.selText)
    else
      setColor(color or C.text)
    end
    if right then
      love.graphics.printf(right, 18, y + 4, W - 36, "right")
      -- Keep long names on one line so they don't run into the size.
      local _, lines = fonts.main:getWrap(text, W - 150)
      text = (lines[1] or "") .. (#lines > 1 and "..." or "")
    end
    love.graphics.printf(text, 18, y + 4, W - 36, "left")
  end
  if count > ROWS then
    setColor(C.dim)
    love.graphics.setFont(fonts.small)
    love.graphics.printf(s.sel .. "/" .. count, 0, 14, W - 14, "right")
  end
end

local function drawCenter(text, color)
  setColor(color or C.text)
  love.graphics.setFont(fonts.main)
  love.graphics.printf(text, 40, 180, W - 80, "center")
end

local function drawPopup()
  setColor({ 0, 0, 0 }, 0.7)
  love.graphics.rectangle("fill", 0, 0, W, H)
  setColor(C.bar)
  love.graphics.rectangle("fill", 50, 120, W - 100, 240, 8, 8)
  setColor(C.sel)
  love.graphics.setFont(fonts.big)
  love.graphics.printf(popup.title, 70, 136, W - 140, "center")
  setColor(C.text)
  love.graphics.setFont(fonts.small)
  love.graphics.printf(popup.text or "", 70, 180, W - 140, "center")
  setColor(C.dim)
  local hint = "A " .. (popup.aLabel or "OK")
  if popup.yLabel then hint = hint .. "     Y " .. popup.yLabel end
  if popup.bLabel then hint = hint .. "     B " .. popup.bLabel end
  love.graphics.setFont(fonts.main)
  love.graphics.printf(hint, 70, 320, W - 140, "center")
end

---------------------------------------------------------------- screen: home
screens.home = {}

function screens.home.items()
  local items = {}
  for _, c in ipairs(app.cats) do items[#items + 1] = { kind = "cat", cat = c } end
  if app.libraryId and app.libState ~= "loading" and #(app.driveFolders or {}) == 0 then
    items[#items + 1] = { kind = "libhint" }
  end
  items[#items + 1] = { kind = "history" }
  items[#items + 1] = { kind = "settings" }
  return items
end

local startLink, linkMenu

local function driveSource(cat)
  for _, src in ipairs(cat.sources) do
    if src.url:match("^gdrive:") then return src end
  end
end

local function openCategory(cat)
  if #cat.sources == 0 and cat.badLink then
    message("Check this link", "The link for " .. cat.short .. " in drive_links.ini isn't a Drive folder link:\n\n"
      .. cat.badLink:sub(1, 80) .. "\n\nIt should look like:\nhttps://drive.google.com/drive/folders/1AbC...\n\nFix it there and press Y, or press X to paste a new one.")
  elseif #cat.sources == 0 then
    startLink(cat)
  elseif #cat.sources == 1 then
    push("browse", { cat = cat, source = cat.sources[1], url = cat.sources[1].url })
  else
    push("sources", { cat = cat })
  end
end

function screens.home.draw(s)
  drawBar("Pocket Drop", "A Open   X Link / change Drive folder   Y Reload   B Quit")
  if app.libraryId then
    local label = ({ loading = "Drive: updating...", ok = "Drive: up to date", cached = "Drive: offline (saved list)",
      error = "Drive: can't connect" })[app.libState] or ""
    setColor(app.libState == "error" and C.bad or C.dim)
    love.graphics.setFont(fonts.small)
    love.graphics.printf(label, 0, 16, W - 14, "right")
  end
  local items = screens.home.items()
  drawList(s, items, function(it)
    if it.kind == "cat" then
      local n = #it.cat.sources
      if it.cat.badLink and n == 0 then return it.cat.name, C.bad, "check link" end
      if n == 0 then return it.cat.name, C.dim, "not linked" end
      if n == 1 and driveSource(it.cat) then return it.cat.name, nil, "Drive" end
      return it.cat.name, nil, n .. (n == 1 and " source" or " sources")
    elseif it.kind == "libhint" then
      return (app.libState == "error" and "Drive library: can't load (A for details)" or "Drive library: no folders yet (A for help)"), C.dim
    elseif it.kind == "history" then return "Downloads history", C.dim
    else return "Settings", C.dim end
  end)
end

function screens.home.action(s, a)
  local items = screens.home.items()
  if a == "up" then moveSel(s, -1, #items)
  elseif a == "down" then moveSel(s, 1, #items)
  elseif a == "y" then
    loadSites()
    refreshLibrary()
    message("Reloaded", "sites.ini reloaded." .. (app.libraryId and "\nChecking your Drive library..." or ""))
  elseif a == "b" then askQuit()
  elseif a == "x" then
    local it = items[s.sel]
    if it and it.kind == "cat" then linkMenu(it.cat) end
  elseif a == "a" then
    local it = items[s.sel]
    if not it then return end
    if it.kind == "cat" then openCategory(it.cat)
    elseif it.kind == "libhint" then
      if app.libState == "error" then
        message("Drive library", app.libError or "Couldn't load the library folder.")
      else
        message("Drive library", "Create folders inside your shared Drive folder, one per console, e.g.\n'Game Boy Advance', 'SNES'.\nEach folder becomes a category here and saves to ROMS/<folder name>.\n\nThen press Y here to refresh.")
      end
    elseif it.kind == "history" then push("history")
    else push("settings") end
  end
end

---------------------------------------------------------------- screen: sources
screens.sources = {}

function screens.sources.draw(s)
  drawBar(s.cat.name, "A Open   B Back")
  drawList(s, s.cat.sources, function(src) return src.name end)
end

function screens.sources.action(s, a)
  local n = #s.cat.sources
  if a == "up" then moveSel(s, -1, n)
  elseif a == "down" then moveSel(s, 1, n)
  elseif a == "b" then pop()
  elseif a == "a" then
    local src = s.cat.sources[s.sel]
    push("browse", { cat = s.cat, source = src, url = src.url })
  end
end

---------------------------------------------------------------- screen: browse
screens.browse = {}

local function sortItems(items)
  table.sort(items, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
end

local load

-- Internet Archive items: read <item>_files.xml instead of the web page.
local function loadArchive(s, id, prefix)
  local function show(files)
    s.loading = false
    s.items = L.archiveChildren(files, id, prefix, app.settings.show_hidden)
    U.log("found " .. #s.items .. " entries (from " .. id .. "_files.xml)")
    if #s.items == 0 then s.error = "This item has no downloadable files here." end
  end
  if app.iaCache[id] then show(app.iaCache[id]) return end
  local xmlUrl = L.archiveXmlUrl(id)
  U.log("open " .. xmlUrl)
  s.job = sendJob({ kind = "fetch", url = xmlUrl }, function(r)
    if s.job ~= r.id then return end
    local files = (r.code == 0) and L.parseArchiveFiles(r.body or "") or {}
    if #files == 0 then
      -- No usable XML: fall back to reading the normal folder page.
      U.log("files.xml not usable (" .. tostring(r.code) .. " " .. tostring(r.err) .. "), using the web page")
      s.noXml = true
      load(s)
      return
    end
    app.iaCache[id] = files
    show(files)
  end)
end

-- Google Drive folders: list them with the Drive API, page by page.
local function loadDrive(s, folderId)
  if not app.gdriveKey or app.gdriveKey == "" then
    s.loading = false
    s.error = "Google Drive needs your API key.\nAdd it to sites.ini under [Google Drive]:\napi_key = AIza..."
    return
  end
  local items, skipped = {}, 0
  local function page(token)
    U.log("open Google Drive folder " .. folderId .. (token and " (next page)" or ""))
    s.job = sendJob({ kind = "fetch", url = G.listUrl(folderId, app.gdriveKey, token) }, function(r)
      if s.job ~= r.id then return end
      if r.code ~= 0 then
        s.loading = false
        s.error = G.explain(r.code, r.err) or errorText(r.code, r.err)
        U.log("Drive list failed (" .. tostring(r.code) .. "): " .. tostring(r.err))
        return
      end
      local got, nextToken, skip, perr = G.parseList(r.body, app.gdriveKey, app.settings.show_hidden)
      if not got then
        s.loading = false
        s.error = "Couldn't read Google's answer:\n" .. tostring(perr)
        U.log("Drive answer not readable: " .. tostring(perr))
        return
      end
      for _, it in ipairs(got) do items[#items + 1] = it end
      skipped = skipped + skip
      if nextToken then page(nextToken) return end
      sortItems(items)
      U.log("found " .. #items .. " entries in Drive folder" .. (skipped > 0 and (", skipped " .. skipped .. " Google Docs") or ""))
      if #items > 0 or skipped > 0 then
        s.loading, s.items = false, items
        if #items == 0 then s.error = "Only Google Docs/Sheets here - upload real files." end
        return
      end
      -- Nothing listed: is the folder empty, or just not shared?
      s.job = sendJob({ kind = "fetch", url = G.metaUrl(folderId, app.gdriveKey) }, function(m)
        if s.job ~= m.id then return end
        s.loading, s.items = false, {}
        if m.code ~= 0 then
          s.error = "Google can't see this folder.\nIn Drive: right-click it -> Share -> General access:\n'Anyone with the link' (Viewer)."
          U.log("Drive folder not visible (" .. tostring(m.code) .. "): probably not shared")
        else
          s.error = "This Drive folder is shared, but it's empty."
        end
      end)
    end)
  end
  page(nil)
end

function load(s)
  s.loading, s.error, s.items = true, nil, {}
  local driveId = G.folderId(s.url)
  if driveId then loadDrive(s, driveId) return end
  local id, prefix = L.archiveItem(s.url)
  if id and not s.noXml then loadArchive(s, id, prefix) return end
  U.log("open " .. s.url)
  s.job = sendJob({ kind = "fetch", url = s.url }, function(r)
    if s.job ~= r.id then return end
    s.loading = false
    if r.code ~= 0 then
      s.error = errorText(r.code, r.err)
      U.log("fetch failed (" .. tostring(r.code) .. "): " .. tostring(r.err))
      return
    end
    s.items = L.parse(r.body or "", s.url, app.settings.show_hidden)
    -- The site may have sent the page from another address (redirect):
    -- read the links against that address too.
    local eff = r.eff or ""
    if eff:match("^https?://") and eff ~= s.url then
      if not eff:match("/$") then eff = eff:match("^(.*/)") or eff end
      U.log("page came from " .. eff)
      local seen = {}
      for _, it in ipairs(s.items) do seen[it.name] = true end
      for _, it in ipairs(L.parse(r.body or "", eff, app.settings.show_hidden)) do
        if not seen[it.name] then s.items[#s.items + 1] = it; seen[it.name] = true end
      end
      sortItems(s.items)
    end
    U.log("found " .. #s.items .. " entries")
    if #s.items == 0 then
      s.error = "Nothing to show here.\nThis address may not be a plain folder listing."
    end
  end)
end

-- Free memory in a RAM-backed folder (tmpfs) we can download into, or nil.
local function ramWorkspace(size)
  if not app.onDevice or U.isWindows then return nil end
  local mounts = U.readFile("/proc/mounts") or ""
  local dir
  if mounts:find(" /tmp tmpfs ", 1, true) then dir = "/tmp/pocketdrop"
  elseif mounts:find(" /dev/shm tmpfs ", 1, true) then dir = "/dev/shm/pocketdrop" end
  if not dir then return nil end
  local avail = tonumber((U.readFile("/proc/meminfo") or ""):match("MemAvailable:%s*(%d+)") or 0) * 1024
  -- keep plenty free for muOS: use at most 60% of free memory, and 192 MB
  local limit = math.min(192 * 1024 * 1024, avail * 0.6)
  if not size or size <= 0 or size > limit then return nil end
  return dir
end

local function startDownload(s, item)
  local root = romRoot()
  local dir = root .. "/" .. s.cat.folder
  if not U.mkdir(dir) then
    message("Can't save", "Couldn't create the folder:\n" .. dir)
    return
  end
  local name = U.safeName(item.name)
  local final = dir .. "/" .. name
  -- Download into memory (RAM) when the file fits: an interrupted download then
  -- can't leave anything on the SD card. Only the finished, checked file is
  -- copied to the card. Very big files go to a hidden ".partial" folder instead.
  local ramdir = ramWorkspace(item.size)
  local partdir = ramdir or (dir .. "/.partial")
  local part = partdir .. "/" .. name .. ".part"
  local function go()
    deletePartial(part)               -- never continue an old, possibly damaged download
    if not U.mkdir(partdir) then
      message("Can't save", "Couldn't create the folder:\n" .. partdir)
      return
    end
    push("download", { cat = s.cat, item = item, dir = dir, final = final, part = part, partdir = partdir, ram = ramdir ~= nil })
  end
  if U.exists(final) then
    showPopup({ title = "Already on your console", text = name .. "\n\nDownload it again and replace it?",
      aLabel = "Replace", bLabel = "Skip", onA = go })
  else
    go()
  end
end

function screens.browse.enter(s) load(s) end

function screens.browse.draw(s)
  local crumb = s.crumb or ""
  drawBar(s.cat.name .. (crumb ~= "" and (" / " .. crumb) or ""),
    "A Download/Open   B Back   Y Refresh   L1/R1 Page")
  if s.loading then
    local dots = string.rep(".", math.floor(love.timer.getTime() * 3) % 4)
    drawCenter("Loading" .. dots, C.dim)
  elseif s.error then
    drawCenter(s.error, C.bad)
  else
    drawList(s, s.items, function(it)
      if it.dir then
        return "[ " .. it.name .. " ]", C.sel, it.count and (it.count .. (it.count == 1 and " file" or " files")) or nil
      end
      return it.name, nil, it.size and U.formatBytes(it.size) or nil
    end)
  end
end

function screens.browse.action(s, a)
  local n = s.items and #s.items or 0
  if a == "up" then moveSel(s, -1, n)
  elseif a == "down" then moveSel(s, 1, n)
  elseif a == "l1" then s.sel = math.max(1, s.sel - ROWS)
  elseif a == "r1" then s.sel = math.max(1, math.min(n, s.sel + ROWS))
  elseif a == "y" then
    local id = L.archiveItem(s.url)
    if id then app.iaCache[id] = nil end
    s.noXml = nil
    load(s)
  elseif a == "b" then s.job = nil; pop()
  elseif a == "a" and not s.loading and n > 0 then
    local it = s.items[s.sel]
    if it.dir then
      push("browse", { cat = s.cat, source = s.source, url = it.url, crumb = ((s.crumb and s.crumb ~= "") and (s.crumb .. " / ") or "") .. it.name })
    else
      startDownload(s, it)
    end
  end
end

---------------------------------------------------------------- screen: download
screens.download = {}

function screens.download.enter(s)
  s.state, s.total, s.status = "running", s.item.size or 0, "Downloading..."
  s.got = partialSize(s.part)
  s.pidfile = app.tmp .. "/download.pid"
  s.cancelflag = app.tmp .. "/download.cancel"
  os.remove(s.cancelflag)   -- a new download starts with no cancel request
  s.started, s.lastPoll = love.timer.getTime(), 0
  s.samples = { { t = s.started, b = s.got } }   -- recent sizes, for the live speed
  s.lastGrowth = s.started
  s.speed = 0
  local unzip = s.cat.unzip
  if unzip == nil then unzip = app.settings.unzip end
  U.log("download " .. s.item.url .. " -> " .. s.final .. (s.ram and "  (into memory first)" or "  (straight to the SD card)"))
  boostOn()
  s.job = sendJob({
    kind = "download", url = s.item.url, part = s.part, final = s.final, dir = s.dir,
    partdir = s.partdir, pidfile = s.pidfile, cancelflag = s.cancelflag, total = s.item.size,
    connections = tonumber(app.settings.connections) or 4, md5 = s.item.md5, ram = s.ram,
    unzip = unzip, delzip = app.settings.delete_zip,
  }, function(r)
    if r.kind == "total" then
      if (s.total or 0) <= 0 and r.total and r.total > 0 then s.total = r.total end
      return
    end
    if r.kind == "status" then
      s.status = r.text
      s.phaseStart = love.timer.getTime()
      U.log("download: " .. r.text)
      return
    end
    boostOff()
    if s.state == "cancelled" or r.stage == "cancelled" then return end
    if r.ok then
      s.state = "ok"
      addHistory("ok", s.cat.name, s.item.name)
      U.log("download finished: " .. s.final)
    else
      s.state = "failed"
      local isDrive = s.item.url:find("googleapis.com", 1, true)
      s.errorText = (r.stage == "unzip" and "Downloaded, but unzipping failed.\n\n" .. (r.err or ""))
        or ((r.stage == "verify" or r.stage == "save") and r.err)
        or (isDrive and G.explain(r.code, r.err)) or errorText(r.code, r.err)
      deletePartial(s.part)
      if not s.ram then os.remove(s.partdir) end
      s.errorText = s.errorText .. "\n\nThe unfinished download was deleted."
      addHistory("failed", s.cat.name, s.item.name)
      U.log("download failed at " .. tostring(r.stage) .. " (" .. tostring(r.code) .. "): " .. tostring(r.err))
    end
  end)
end

local function cancelDownload(s, deletePart)
  s.state = "cancelled"
  s.deleted = deletePart
  U.writeFile(s.cancelflag, "stop")   -- tells the worker not to retry
  if U.isWindows then
    os.execute("taskkill /F /IM curl.exe >nul 2>nul")
  else
    -- stop every connection of this download
    for pid in (U.readFile(s.pidfile) or ""):gmatch("%d+") do os.execute("kill " .. pid .. " >/dev/null 2>&1") end
  end
  boostOff()
  -- the worker may still be closing the file: delete now, and again on screen exit
  deletePartial(s.part)
  addHistory("cancelled", s.cat.name, s.item.name)
  U.log("download cancelled and deleted")
end

function screens.download.update(s)
  if s.state ~= "running" then return end
  local now = love.timer.getTime()
  if now - s.lastPoll > 0.25 then
    s.lastPoll = now
    local now_got = partialSize(s.part)
    -- At the end the pieces are joined and moved, so the partial file shrinks or
    -- disappears: keep the highest value instead of dropping back to 0.
    if now_got > s.got then
      s.got, s.lastGrowth = now_got, now
      if s.status == "Connection stalled - reconnecting..." then s.status = "Downloading..." end
    end
    s.lastGrowth = s.lastGrowth or now
    -- live speed: bytes gained over the last ~4 seconds
    table.insert(s.samples, { t = now, b = s.got })
    while #s.samples > 2 and now - s.samples[1].t > 4 do table.remove(s.samples, 1) end
    local first = s.samples[1]
    if now - first.t > 0.5 then s.speed = math.max(0, (s.got - first.b) / (now - first.t)) end
    local busy = s.status:find("Saving", 1, true) or s.status:find("Unzipping", 1, true) or s.status:find("Checking", 1, true) or s.status:find("Joining", 1, true)
    if not busy and now - s.lastGrowth > 25 and now - (s.lastKick or 0) > 25 then
      s.lastKick = now
      s.status = "Connection stalled - reconnecting..."
      U.log("no data for 25 s: restarting the connections")
      if not U.isWindows then
        -- snapshot of what's running, so the log shows what got stuck
        local p = io.popen("ps 2>/dev/null | grep -E 'curl|head|sync|unzip|cat ' | grep -v grep")
        local out = p and p:read("*a") or ""
        if p then p:close() end
        for line in out:gmatch("[^\n]+") do U.log("  running: " .. line) end
      end
      for pid in (U.readFile(s.pidfile) or ""):gmatch("%d+") do os.execute("kill " .. pid .. " >/dev/null 2>&1") end
    end
  end
end

function screens.download.draw(s)
  local title = ({ running = "Downloading", ok = "Done!", failed = "Download failed", cancelled = "Cancelled" })[s.state]
  drawBar(title, s.state == "running" and "B Cancel" or "A Back to folder")
  love.graphics.setFont(fonts.main)
  setColor(C.text)
  love.graphics.printf(s.item.name, 30, 80, W - 60, "center")
  setColor(C.dim)
  love.graphics.setFont(fonts.small)
  love.graphics.printf("Saving to " .. s.dir, 30, 130, W - 60, "center")

  if s.state == "running" then
    -- If the file turns out bigger than expected, show "unknown size" instead of
    -- a full bar; and never show 100% until the download has really finished.
    if s.total > 0 and s.got > s.total then s.total = 0 end
    local frac = (s.total > 0) and math.min(0.99, s.got / s.total) or nil
    setColor(C.bar)
    love.graphics.rectangle("fill", 60, 220, W - 120, 30, 6, 6)
    setColor(C.sel)
    if frac then
      love.graphics.rectangle("fill", 60, 220, (W - 120) * frac, 30, 6, 6)
    else
      local x = (love.timer.getTime() * 200) % (W - 180)
      love.graphics.rectangle("fill", 60 + x, 220, 60, 30, 6, 6)
    end
    local busy = s.status:find("Saving", 1, true) or s.status:find("Unzipping", 1, true) or s.status:find("Checking", 1, true) or s.status:find("Joining", 1, true)
    local quiet = love.timer.getTime() - (s.lastGrowth or love.timer.getTime())
    local speedText
    if busy then speedText = ""
    elseif s.speed > 0 then speedText = U.formatBytes(s.speed) .. "/s"
    elseif quiet < 3 then speedText = "starting..."
    elseif s.total > 0 and s.got >= s.total * 0.97 then
      speedText = "waiting for the last piece (" .. math.floor(quiet) .. "s)"
    else speedText = "no data for " .. math.floor(quiet) .. "s" end
    local line = U.formatBytes(s.got) .. " / " .. U.formatBytes(s.total) .. "   " .. speedText
    if frac then line = math.floor(frac * 100) .. "%   " .. line end
    setColor(C.text)
    love.graphics.setFont(fonts.main)
    love.graphics.printf(line, 30, 270, W - 60, "center")
    setColor(C.dim)
    local status = s.status
    if frac and frac >= 0.99 and not (status:find("Saving", 1, true) or status:find("Unzipping", 1, true) or status:find("Checking", 1, true) or status:find("Joining", 1, true)) then
      status = "Finishing..."
    end
    if s.phaseStart and (status:find("Saving", 1, true) or status:find("Unzipping", 1, true) or status:find("Checking", 1, true) or status:find("Joining", 1, true)) then
      status = status .. "  (" .. math.floor(love.timer.getTime() - s.phaseStart) .. "s)"
    end
    love.graphics.printf(status, 30, 310, W - 60, "center")
  elseif s.state == "ok" then
    drawCenter("Saved. It's ready in your " .. s.cat.folder .. " folder.\nKeep the lid open during downloads.", C.ok)
  elseif s.state == "failed" then
    drawCenter(s.errorText or "Unknown error", C.bad)
  else
    drawCenter(s.deleted and "The download was cancelled and deleted."
      or "The download was cancelled and deleted.", C.dim)
  end
end

function screens.download.action(s, a)
  if s.state == "running" then
    if a == "b" then
      showPopup({ title = "Cancel download?", text = "The unfinished download will be deleted.",
        aLabel = "Cancel download", bLabel = "Keep going",
        onA = function() if s.state == "running" then cancelDownload(s, true) end end })
    end
  elseif a == "a" or a == "b" then
    if s.state ~= "ok" then
      deletePartial(s.part)
      if not s.ram then os.remove(s.partdir) end
    end
    s.item.partial = nil
    pop()
  end
end

---------------------------------------------------------------- screen: history
screens.history = {}

function screens.history.enter(s)
  s.items = {}
  local text = U.readFile(app.historyPath) or ""
  for line in text:gmatch("[^\r\n]+") do table.insert(s.items, 1, line) end
  while #s.items > 50 do table.remove(s.items) end
end

function screens.history.draw(s)
  drawBar("Downloads history", "B Back")
  if #s.items == 0 then drawCenter("Nothing downloaded yet.", C.dim) return end
  love.graphics.setFont(fonts.small)
  drawList(s, s.items, function(line)
    local color = line:find("| ok |", 1, true) and C.ok or (line:find("| failed |", 1, true) and C.bad or C.dim)
    return line, color
  end)
end

function screens.history.action(s, a)
  if a == "up" then moveSel(s, -1, #s.items)
  elseif a == "down" then moveSel(s, 1, #s.items)
  elseif a == "b" then pop() end
end

---------------------------------------------------------------- screen: settings
screens.settings = {}

local function onOff(v) return v and "ON" or "OFF" end

function screens.settings.items()
  return {
    { key = "unzip", label = "Unzip .zip files after download: " .. onOff(app.settings.unzip) },
    { key = "delete_zip", label = "Delete the .zip after unzipping: " .. onOff(app.settings.delete_zip) },
    { key = "roms", label = "ROMS folder: " .. tostring(romRoot()) },
    { key = "connections", label = "Connections per download: " .. tostring(app.settings.connections or 4) .. "  (more = faster on weak Wi-Fi)" },
    { key = "boost", label = "Speed boost while downloading: " .. onOff(app.settings.boost ~= false) },
    { key = "show_hidden", label = "Show hidden files: " .. onOff(app.settings.show_hidden) },
    { key = "gsetup", label = "Google API key" .. ((app.gdriveKey and app.gdriveKey ~= "") and "  (saved)" or "  (not set)") },
    { key = "buttons", label = "Button test" },
    { key = "calibrate", label = "Button setup (only if buttons don't work)" },
    { key = "about", label = "About Pocket Drop" },
  }
end

function screens.settings.draw(s)
  drawBar("Settings", "A Change   B Back")
  drawList(s, screens.settings.items(), function(it) return it.label end)
end

function screens.settings.action(s, a)
  local items = screens.settings.items()
  if a == "up" then moveSel(s, -1, #items)
  elseif a == "down" then moveSel(s, 1, #items)
  elseif a == "b" then pop()
  elseif a == "a" or a == "left" or a == "right" then
    local k = items[s.sel].key
    if k == "connections" then
      local nextC = { ["1"] = "2", ["2"] = "4", ["4"] = "1" }
      app.settings.connections = nextC[tostring(app.settings.connections)] or "4"
      saveSettings()
    elseif k == "boost" then
      app.settings.boost = not (app.settings.boost ~= false)
      saveSettings()
    elseif k == "unzip" or k == "delete_zip" or k == "show_hidden" then
      app.settings[k] = not app.settings[k]
      saveSettings()
    elseif k == "roms" then
      local cur, idx = romRoot(), 1
      for i, r in ipairs(app.romRoots) do if r == cur then idx = i end end
      app.settings.roms_root = app.romRoots[(idx % #app.romRoots) + 1]
      saveSettings()
    elseif k == "gsetup" and a == "a" then push("gsetup")
    elseif k == "buttons" and a == "a" then push("buttons")
    elseif k == "calibrate" and a == "a" then push("calibrate")
    elseif k == "about" and a == "a" then
      message("Pocket Drop " .. VERSION, "App folder:\n" .. app.dir .. "\n\nDownload tool: " .. app.tool
        .. "\n\nOnly download files you have the right to use.")
    end
  end
end

---------------------------------------------------------------- screen: button test
screens.buttons = {}

function screens.buttons.draw(s)
  drawBar("Button test", "Hold B for 2 seconds to leave")
  love.graphics.setFont(fonts.main)
  for i, line in ipairs(buttonLog) do
    setColor(i == 1 and C.sel or C.text)
    love.graphics.printf(line, 30, LIST_Y + (i - 1) * ROW_H, W - 60, "left")
  end
  if #buttonLog == 0 then drawCenter("Press any button.", C.dim) end
end

function screens.buttons.action() end

function screens.buttons.update()
  if held.b and love.timer.getTime() - held.b > 2 then held.b = nil; pop() end
end

---------------------------------------------------------------- screen: fatal
screens.fatal = {}
function screens.fatal.draw()
  drawBar("Can't start", "B Quit")
  setColor(C.bad)
  love.graphics.setFont(fonts.main)
  love.graphics.printf(app.fatal or "", 30, 70, W - 60, "left")
end
function screens.fatal.action(_, a) if a == "b" or a == "a" then quitApp() end end

---------------------------------------------------------------- screen: keyboard
-- On-screen keyboard. Opened with push("keyboard", { title, value, hint, onDone }).
-- Gamepad: D-pad move, A type, B delete, X capitals, Y space, Start OK, Select cancel.
-- PC: just type or paste (Ctrl+V); Enter = OK, Esc = cancel.
screens.keyboard = {}
local KB_ROWS = { "1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm_./", ":?=&%+@#~!" }
local KB_BOTTOM = { "Aa", "Space", "Clear", "Del", "OK" }
local KW, KH, KX, KY = 58, 40, 30, 150

function screens.keyboard.enter(s)
  s.value = s.value or ""
  s.row, s.col, s.caps = 1, 1, false
end

local function kbChar(s, r, c)
  local ch = KB_ROWS[r]:sub(c, c)
  return s.caps and ch:upper() or ch
end

local function kbDone(s)
  local value, cb = s.value, s.onDone
  pop()
  if cb then cb(value) end
end

local function kbCancel(s)
  showPopup({ title = "Discard?", text = "Leave without saving what you typed?", aLabel = "Discard",
    bLabel = "Keep typing", onA = function() pop(); if s.onCancel then s.onCancel() end end })
end

local function kbPress(s)
  if s.row <= #KB_ROWS then
    s.value = s.value .. kbChar(s, s.row, s.col)
    return
  end
  local k = KB_BOTTOM[math.floor((s.col - 1) / 2) + 1]
  if k == "Aa" then s.caps = not s.caps
  elseif k == "Space" then s.value = s.value .. " "
  elseif k == "Clear" then s.value = ""
  elseif k == "Del" then s.value = s.value:sub(1, -2)
  elseif k == "OK" then kbDone(s) end
end

function screens.keyboard.draw(s)
  drawBar(s.title or "Type", "A Type  B Delete  X Aa  Y Space  Start OK  Select Cancel")
  love.graphics.setFont(fonts.small)
  setColor(C.dim)
  love.graphics.printf(s.hint or "", 20, 52, W - 40, "left")
  -- text box (shows the end of long text)
  setColor(C.bar)
  love.graphics.rectangle("fill", 20, 100, W - 40, 36, 4, 4)
  setColor(C.text)
  love.graphics.setFont(fonts.main)
  local shown = s.value
  while #shown > 0 and fonts.main:getWidth(shown .. "_") > W - 60 do shown = shown:sub(2) end
  local blink = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "_" or ""
  love.graphics.print(shown .. blink, 30, 107)
  setColor(C.dim)
  love.graphics.setFont(fonts.small)
  love.graphics.printf(#s.value .. (#s.value == 1 and " character" or " characters"), 20, 138, W - 40, "right")
  -- keys
  love.graphics.setFont(fonts.main)
  for r, row in ipairs(KB_ROWS) do
    for c = 1, #row do
      local x, y = KX + (c - 1) * KW, KY + (r - 1) * KH + 8
      local on = (s.row == r and s.col == c)
      setColor(on and C.sel or C.bar)
      love.graphics.rectangle("fill", x, y, KW - 4, KH - 4, 4, 4)
      setColor(on and C.selText or C.text)
      love.graphics.printf(kbChar(s, r, c), x, y + 7, KW - 4, "center")
    end
  end
  local y = KY + #KB_ROWS * KH + 8
  for i, k in ipairs(KB_BOTTOM) do
    local x = KX + (i - 1) * KW * 2
    local on = (s.row > #KB_ROWS and math.floor((s.col - 1) / 2) + 1 == i)
    setColor(on and C.sel or C.bar)
    love.graphics.rectangle("fill", x, y, KW * 2 - 4, KH - 4, 4, 4)
    setColor(on and C.selText or (k == "OK" and C.ok or C.text))
    love.graphics.printf((k == "Aa" and s.caps) and "AA" or k, x, y + 7, KW * 2 - 4, "center")
  end
end

function screens.keyboard.action(s, a)
  local rows = #KB_ROWS + 1
  if a == "up" then s.row = (s.row - 2) % rows + 1
  elseif a == "down" then s.row = s.row % rows + 1
  elseif a == "left" then s.col = (s.col - 2) % 10 + 1
  elseif a == "right" then s.col = s.col % 10 + 1
  elseif a == "a" then kbPress(s)
  elseif a == "b" then s.value = s.value:sub(1, -2)
  elseif a == "x" then s.caps = not s.caps
  elseif a == "y" then s.value = s.value .. " "
  elseif a == "start" then kbDone(s)
  elseif a == "select" then kbCancel(s)
  end
end

---------------------------------------------------------------- Google Drive: key setup + linking
-- Editing sites.ini for a console: its [section] keeps one Google Drive line
-- ("source = Google Drive | gdrive:ID"), so each console has one Drive folder.

local function sectionName(cat) return cat.section or cat.name end

local function saveDriveLink(cat, folderId)
  if cat.builtin then
    local text = U.readFile(app.linksPath) or U.linksTemplate(CONSOLES, app.gdriveKey)
    local ok = U.writeFile(app.linksPath, U.linksSet(text, cat.short, "https://drive.google.com/drive/folders/" .. folderId))
    -- tidy: an old Drive line for this console in sites.ini would be confusing
    local st = U.readFile(app.sitesPath)
    if st and cat.section then U.writeFile(app.sitesPath, U.iniRemoveSources(st, cat.section, "gdrive:")) end
    return ok
  end
  local text = U.readFile(app.sitesPath) or U.DEFAULT_SITES
  local sec = sectionName(cat)
  text = U.iniRemoveSources(text, sec, "gdrive:")
  if U.iniHasSection(text, sec) then
    text = U.iniAppend(text, sec, "source = Google Drive | gdrive:" .. folderId)
  else
    text = U.iniAppend(text, sec, "source = Google Drive | gdrive:" .. folderId, cat.folder)
  end
  return U.writeFile(app.sitesPath, text)
end

local function removeDriveLink(cat)
  if cat.builtin then
    local text = U.readFile(app.linksPath)
    if text then U.writeFile(app.linksPath, U.linksSet(text, cat.short, "")) end
    local st = U.readFile(app.sitesPath)
    if st and cat.section then U.writeFile(app.sitesPath, U.iniRemoveSources(st, cat.section, "gdrive:")) end
    return true
  end
  local text = U.readFile(app.sitesPath) or ""
  return U.writeFile(app.sitesPath, U.iniRemoveSources(text, sectionName(cat), "gdrive:"))
end

local function reloadEverything()
  loadSites()
  refreshLibrary()
end

local function findCat(name)
  for _, c in ipairs(app.cats) do if c.name == name then return c end end
end

-- Test a Drive folder. done(ok, message, count)
local function testDriveFolder(key, folderId, done)
  return sendJob({ kind = "fetch", url = G.listUrl(folderId, key) }, function(r)
    if r.code ~= 0 then return done(false, G.explain(r.code, r.err) or errorText(r.code, r.err)) end
    local items, _, skipped, perr = G.parseList(r.body, key, true)
    if not items then return done(false, "Couldn't read Google's answer:\n" .. tostring(perr)) end
    if #items + skipped > 0 then return done(true, nil, #items) end
    sendJob({ kind = "fetch", url = G.metaUrl(folderId, key) }, function(m2)
      if m2.code ~= 0 then
        done(false, "Google can't see this folder.\nIn Drive: right-click it -> Share -> General access:\n'Anyone with the link' (Viewer). Then press Y.")
      else
        done(true, nil, 0)
      end
    end)
  end)
end

---------------------------------------------------------------- screen: link (test + save a console's folder)
screens.link = {}

function screens.link.enter(s) screens.link.test(s) end

function screens.link.test(s)
  s.testing, s.ok, s.msg = true, false, nil
  U.log("linking " .. s.cat.name .. " to Drive folder " .. s.folderId)
  local myId
  myId = testDriveFolder(app.gdriveKey, s.folderId, function(ok, msg, count)
    if s.gone then return end
    s.testing, s.ok, s.msg, s.count = false, ok, msg, count
  end)
end

function screens.link.draw(s)
  drawBar(s.cat.name, s.testing and "Please wait..." or (s.ok and "A Save and open   B Cancel" or "Y Test again   A Change link   B Cancel"))
  if s.testing then
    drawCenter("Checking your Drive folder" .. string.rep(".", math.floor(love.timer.getTime() * 3) % 4), C.dim)
  elseif s.ok then
    drawCenter("Connected!\n\nFound " .. s.count .. " item" .. (s.count == 1 and "" or "s") .. " in the folder.\n\nDownloads will go to ROMS/" .. s.cat.folder, C.ok)
  else
    drawCenter(s.msg or "Something went wrong.", C.bad)
  end
end

function screens.link.action(s, a)
  if s.testing then return end
  if a == "b" then s.gone = true; pop()
  elseif a == "y" and not s.ok then screens.link.test(s)
  elseif a == "a" and not s.ok then s.gone = true; pop(); startLink(s.cat, s.typed)
  elseif a == "a" and s.ok then
    if not saveDriveLink(s.cat, s.folderId) then
      message("Couldn't save", "Your link could not be saved in:\n" .. (s.cat.builtin and app.linksPath or app.sitesPath))
      return
    end
    U.log("linked " .. s.cat.name .. " -> Drive folder")
    s.gone = true
    local name = s.cat.name
    pop()
    reloadEverything()
    local cat = findCat(name)
    local src = cat and driveSource(cat)
    if src then push("browse", { cat = cat, source = src, url = src.url }) end
  end
end

-- Ask for a console's Drive folder link (asks for the API key first if needed).
startLink = function(cat, typed)
  if not app.gdriveKey or app.gdriveKey == "" then
    push("gsetup", { onSaved = function() startLink(cat) end })
    return
  end
  local cur = driveSource(cat)
  push("keyboard", {
    title = "Drive folder for " .. (cat.short or cat.name),
    value = typed or (cur and ("https://drive.google.com/drive/folders/" .. cur.url:match("^gdrive:(.+)$"))) or "",
    hint = "Paste the share link of your Google Drive folder for\n" .. cat.name .. " (Share -> Anyone with the link -> Copy link).",
    onDone = function(v)
      local id = G.parseInput(v)
      if not id then
        message("That's not a folder link", "It should look like:\nhttps://drive.google.com/drive/folders/1AbC...\n\nPress X on the console to try again.")
        return
      end
      push("link", { cat = cat, folderId = id, typed = v })
    end })
end

linkMenu = function(cat)
  if not driveSource(cat) then startLink(cat) return end
  showPopup({ title = cat.name, text = "This console is linked to a Google Drive folder.\nDownloads go to ROMS/" .. cat.folder .. ".",
    aLabel = "Change link", yLabel = "Remove link", bLabel = "Cancel",
    onA = function() startLink(cat) end,
    onY = function()
      removeDriveLink(cat)
      reloadEverything()
      message("Link removed", cat.name .. " is no longer linked.")
    end })
end

---------------------------------------------------------------- screen: Google Drive key setup
screens.gsetup = {}

local GUIDE = {
  { "Connect your Google Drive",
    "Each console here can download from a Google Drive folder\nwith your own files.\n\n"
    .. "First you need a free Google API key (one time, ~10 min).\n"
    .. "The next 2 pages show how, on a PC or phone.\n\n"
    .. "Tip: typing a long key with the D-pad is slow. Run Pocket Drop\non your PC and do this there - you can paste with Ctrl+V -\nthen copy the folder to the console.\n\n"
    .. "Full guide: GOOGLE-DRIVE-SETUP.txt in the app folder." },
  { "Step 1 of 2 - Create a project",
    "Go to  console.cloud.google.com\n\n"
    .. "1. Sign in with your Google account (no payment card needed).\n"
    .. "2. Project picker at the top -> NEW PROJECT\n   (Proyecto nuevo).\n"
    .. "3. Name it Pocket Drop -> CREATE, then select it at the top.\n"
    .. "4. Menu -> APIs & Services -> Library\n   (APIs y servicios -> Biblioteca).\n"
    .. "5. Search 'Google Drive API' -> open it -> ENABLE (Habilitar)." },
  { "Step 2 of 2 - Make the key",
    "1. APIs & Services -> Credentials (Credenciales)\n   -> CREATE CREDENTIALS -> API key.\n"
    .. "2. Copy the key. It starts with AIza, 39 characters.\n"
    .. "3. Optional: edit the key -> Restrict key ->\n   tick only 'Google Drive API' -> Save.\n\n"
    .. "Then, for each console, share a Drive folder:\n"
    .. "right-click it -> Share -> 'Anyone with the link' (Viewer)\n-> Copy link. Keep those links private.\n\n"
    .. "Only use files you have the right to use." },
}

function screens.gsetup.enter(s)
  s.page = 1
end

local function gsetupSaveKey(s, key)
  local text = U.readFile(app.linksPath) or U.linksTemplate(CONSOLES, nil)
  if not U.writeFile(app.linksPath, U.linksSet(text, "api_key", key)) then
    message("Couldn't save", "drive_links.ini could not be written:\n" .. app.linksPath)
    return
  end
  U.log("Google API key saved")
  reloadEverything()
  local after = s.onSaved
  pop()
  if after then after() else message("Key saved", "Now press X on a console to link its Drive folder.") end
end

local function gsetupAskKey(s, value)
  push("keyboard", { title = "Google API key", value = value or app.gdriveKey or "",
    hint = "Starts with AIza, 39 characters. Capitals matter (X = capitals).",
    onDone = function(v)
      v = v:gsub("%s", "")
      if not v:match("^AIza") or #v ~= 39 then
        showPopup({ title = "Check the key", text = "A Google API key starts with AIza and has 39 characters.\nYours has " .. #v .. ".",
          aLabel = "Use it anyway", bLabel = "Fix it",
          onA = function() gsetupSaveKey(s, v) end, onB = function() gsetupAskKey(s, v) end })
        return
      end
      gsetupSaveKey(s, v)
    end })
end

function screens.gsetup.draw(s)
  local g = GUIDE[s.page]
  drawBar(g[1], (s.page < #GUIDE and "A Next" or "A Type the key") .. "   B Back")
  setColor(C.text)
  love.graphics.setFont(fonts.small)
  love.graphics.printf(g[2], 30, 62, W - 60, "left")
  setColor(C.dim)
  love.graphics.printf("Page " .. s.page .. " of " .. #GUIDE, 30, H - 60, W - 60, "right")
end

function screens.gsetup.action(s, a)
  if a == "a" then
    if s.page < #GUIDE then s.page = s.page + 1 else gsetupAskKey(s) end
  elseif a == "b" then
    if s.page > 1 then s.page = s.page - 1 else pop() end
  end
end

---------------------------------------------------------------- screen: button setup (fallback)
-- Only used if SDL doesn't recognise the controls as a standard gamepad.
-- Asks for each button once and saves the raw numbers in settings.txt.
screens.calibrate = {}
local CAL_STEPS = {
  { "a", "A (confirm)" }, { "b", "B (back)" }, { "x", "X" }, { "y", "Y" },
  { "l1", "L1" }, { "r1", "R1" }, { "start", "START" }, { "select", "SELECT" },
  { "up", "D-pad UP" }, { "down", "D-pad DOWN" }, { "left", "D-pad LEFT" }, { "right", "D-pad RIGHT" },
}
local rawMap = {}        -- raw button number -> action

local function loadRawMap()
  rawMap = {}
  for k, v in tostring(app.settings.raw_map or ""):gmatch("(%d+)=(%a+%d?)") do rawMap[tonumber(k)] = v end
end

local function saveRawMap()
  local parts = {}
  for k, v in pairs(rawMap) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  app.settings.raw_map = table.concat(parts, ",")
  saveSettings()
end

function screens.calibrate.enter(s)
  s.step, s.map, s.stepStart = 1, {}, love.timer.getTime()
end

local function calNext(s)
  s.step, s.stepStart = s.step + 1, love.timer.getTime()
  if s.step > #CAL_STEPS then
    rawMap = s.map
    saveRawMap()
    U.log("button setup saved: " .. tostring(app.settings.raw_map))
    pop()
    message("Buttons saved", "You can redo this any time in Settings -> Button setup.")
  end
end

function screens.calibrate.raw(s, button)
  s.map[button] = CAL_STEPS[s.step][1]
  calNext(s)
end

function screens.calibrate.hat(s, dir)
  -- D-pad reported as a "hat": nothing to store, it already works.
  if s.step >= 9 then calNext(s) end
end

function screens.calibrate.update(s)
  -- no press for 6 seconds = skip this button
  if love.timer.getTime() - s.stepStart > 6 then calNext(s) end
end

function screens.calibrate.draw(s)
  drawBar("Button setup", "Wait 6 seconds to skip a button")
  local step = CAL_STEPS[s.step]
  if not step then return end
  setColor(C.text)
  love.graphics.setFont(fonts.main)
  love.graphics.printf("Your controls need a one-time setup.", 30, 90, W - 60, "center")
  setColor(C.sel)
  love.graphics.setFont(fonts.big)
  love.graphics.printf("Press  " .. step[2], 30, 190, W - 60, "center")
  setColor(C.dim)
  love.graphics.setFont(fonts.small)
  local left = math.max(0, 6 - math.floor(love.timer.getTime() - s.stepStart))
  love.graphics.printf("Button " .. s.step .. " of " .. #CAL_STEPS .. "   (skipping in " .. left .. ")", 30, 260, W - 60, "center")
end

function screens.calibrate.action() end

---------------------------------------------------------------- input
local keyMap = {
  up = "up", down = "down", left = "left", right = "right",
  ["return"] = "a", kpenter = "a", backspace = "b", escape = "b",
  x = "x", y = "y", q = "l1", e = "r1", space = "start", tab = "select",
}
local padMap = {
  dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
  a = "a", b = "b", x = "x", y = "y", leftshoulder = "l1", rightshoulder = "r1",
  start = "start", back = "select", guide = "select",
}

local function note(text)
  table.insert(buttonLog, 1, text)
  while #buttonLog > 11 do table.remove(buttonLog) end
end

local function press(act)
  held[act] = love.timer.getTime()
  if held.start and held.select then quitApp() return end
  if popup then
    local p = popup
    if act == "a" then popup = nil; if p.onA then p.onA() end
    elseif act == "b" then popup = nil; if p.onB then p.onB() end
    elseif act == "y" and p.yLabel then popup = nil; if p.onY then p.onY() end end
    return
  end
  if act == "up" or act == "down" then rep.act, rep.t = act, love.timer.getTime() + 0.35 end
  local s = top()
  screens[s.name].action(s, act)
end

local function release(act)
  held[act] = nil
  if rep.act == act then rep.act = nil end
end

local function kbScreen()
  local s = top()
  return (s and s.name == "keyboard" and not popup) and s or nil
end

function love.textinput(t)
  local s = kbScreen()
  if s then s.value = s.value .. t:gsub("[%c]", "") end
end

function love.keypressed(key)
  local s = kbScreen()
  if s then
    local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
    if ctrl and key == "v" then
      s.value = s.value .. (love.system.getClipboardText() or ""):gsub("[%c]", "")
    elseif key == "return" or key == "kpenter" then kbDone(s)
    elseif key == "escape" then kbCancel(s)
    elseif key == "backspace" then s.value = s.value:sub(1, -2)
    elseif key == "up" or key == "down" or key == "left" or key == "right" then
      screens.keyboard.action(s, key)
    end
    return  -- letters arrive through love.textinput
  end
  local act = keyMap[key]
  note("key " .. key .. " -> " .. tostring(act))
  if act then press(act) end
end
function love.keyreleased(key)
  if kbScreen() then return end
  local act = keyMap[key]; if act then release(act) end
end

function love.gamepadpressed(_, button)
  local act = padMap[button]
  note("pad " .. button .. " -> " .. tostring(act))
  if act then press(act) end
end
function love.gamepadreleased(_, button) local act = padMap[button]; if act then release(act) end end

-- Fallback for controls SDL doesn't recognise as a standard gamepad:
-- use the button numbers saved by the one-time button setup.
function love.joystickpressed(j, button)
  if j:isGamepad() then return end
  note("raw button " .. button .. " -> " .. tostring(rawMap[button]))
  local s = top()
  if s and s.name == "calibrate" then screens.calibrate.raw(s, button) return end
  if rawMap[button] then
    press(rawMap[button])
  elseif not app.calibrateAsked then
    app.calibrateAsked = true
    U.log("controls are not a standard gamepad: starting button setup")
    push("calibrate")
  end
end

function love.joystickreleased(j, button)
  if j:isGamepad() then return end
  if rawMap[button] then release(rawMap[button]) end
end

local hatHeld = nil
function love.joystickhat(j, _, dir)
  if j:isGamepad() then return end
  note("raw hat " .. dir)
  local s = top()
  if s and s.name == "calibrate" then screens.calibrate.hat(s, dir) return end
  local acts = { u = "up", d = "down", l = "left", r = "right" }
  if hatHeld then release(hatHeld); hatHeld = nil end
  if acts[dir] then hatHeld = acts[dir]; press(hatHeld) end
end

---------------------------------------------------------------- LOVE callbacks
function love.load()
  love.keyboard.setKeyRepeat(false)
  app.dir = (love.filesystem.getSource():gsub("\\", "/"))
  app.onDevice = U.exists("/opt/muos")
  app.tmp = app.dir .. "/tmp"
  app.sitesPath = app.dir .. "/sites.ini"
  app.linksPath = app.dir .. "/drive_links.ini"
  app.settingsPath = app.dir .. "/settings.txt"
  app.historyPath = app.dir .. "/history.txt"
  U.mkdir(app.tmp)
  os.remove(app.tmp .. "/download.cancel")
  U.startLog(app.dir .. "/log.txt", "Pocket Drop " .. VERSION .. " started " .. os.date())
  local lower = app.dir:lower()
  if lower:match("%.zip$") or lower:match("%.love$") then
    app.fatal = "You started the .zip file.\n\nRight-click the zip -> Extract All, then drag the extracted PocketDrop folder (the one with main.lua inside) onto LOVE.\n\n" .. app.dir
  elseif not U.exists(app.dir .. "/log.txt") then
    app.fatal = "Pocket Drop can't save files in its folder:\n\n" .. app.dir .. "\n\nMove the PocketDrop folder to Documents or Desktop and start it from there."
  end
  U.log("app folder: " .. app.dir)
  U.log("on muOS device: " .. tostring(app.onDevice))

  app.settings = U.loadSettings(app.settingsPath, { unzip = true, delete_zip = true, show_hidden = false, roms_root = "", raw_map = "",
    boost = true, connections = "4" })
  loadRawMap()

  -- Where can ROMs go? SD2 first if present, then SD1. On a PC: a test folder.
  if app.onDevice then
    for _, p in ipairs({ "/mnt/sdcard/ROMS", "/mnt/mmc/ROMS", "/mnt/union/ROMS" }) do
      if U.exists(p) then app.romRoots[#app.romRoots + 1] = p end
    end
  end
  if #app.romRoots == 0 then
    local test = app.dir .. "/TEST_ROMS"
    U.mkdir(test)
    app.romRoots[1] = test
  end
  U.log("ROMS folder: " .. tostring(romRoot()))

  -- Make sure every console has its folder in ROMS (only missing ones are
  -- created; existing folders and games are never touched).
  do
    local root, made = romRoot(), {}
    if root and U.exists(root) then
      for _, con in ipairs(CONSOLES) do
        local dir = root .. "/" .. con.folder
        if not U.exists(dir) then
          if U.mkdir(dir) then made[#made + 1] = con.folder else U.log("couldn't create " .. dir) end
        end
      end
    end
    if #made > 0 then U.log("created ROMS folders: " .. table.concat(made, ", ")) end
  end

  -- Pick the download tool.
  if U.isWindows then
    app.tool = "curl"
  else
    local r = os.execute("command -v curl >/dev/null 2>&1")
    app.tool = (r == 0 or r == true) and "curl" or "wget"
  end
  U.log("download tool: " .. app.tool)

  if not U.isWindows then os.execute("rm -rf /tmp/pocketdrop /dev/shm/pocketdrop 2>/dev/null") end
  -- Remove unfinished downloads left behind (e.g. the console was switched
  -- off mid-download): hidden .partial folders and old "<game>.part" files.
  for _, root in ipairs(app.romRoots) do
    if not U.isWindows then
      os.execute("find " .. U.quote(root) .. " -mindepth 2 -maxdepth 2 -name '*.part' -exec rm -f {} \\; 2>/dev/null")
      os.execute("find " .. U.quote(root) .. " -mindepth 2 -maxdepth 2 -type d -name '.partial' -exec rm -rf {} \\; 2>/dev/null")
    end
  end

  fonts.main = love.graphics.newFont(18)
  fonts.small = love.graphics.newFont(14)
  fonts.big = love.graphics.newFont(22)

  jobs = love.thread.getChannel("rl_jobs")
  results = love.thread.getChannel("rl_results")
  jobs:clear()
  results:clear()
  worker = love.thread.newThread("worker.lua")
  worker:start()

  if app.fatal then push("fatal") return end
  loadSites()
  refreshLibrary()
  push("home")
end

function love.update()
  -- While a download runs, draw fewer frames so the CPU works on the download.
  local cur = top()
  if cur and cur.name == "download" and cur.state == "running" and not popup then love.timer.sleep(0.06) end
  -- Answers from the background thread.
  while true do
    local r = results:pop()
    if not r then break end
    if r.kind == "log" then
      U.log(r.msg)
    else
      local cb = pending[r.id]
      if cb then
        if r.kind == "fetched" or r.kind == "done" then pending[r.id] = nil end
        cb(r)
      end
    end
  end
  local err = worker and worker:getError()
  if err then
    U.log("worker crashed: " .. err)
    message("Internal error", "The download helper stopped. See log.txt.")
    worker = nil
  end

  -- Hold up/down to scroll quickly.
  if rep.act and not popup and love.timer.getTime() > rep.t then
    rep.t = love.timer.getTime() + 0.07
    local s = top()
    screens[s.name].action(s, rep.act)
  end

  -- Hold L1 + R1 for 2 seconds on Home to open the button test.
  local s = top()
  if s.name == "home" and held.l1 and held.r1 and love.timer.getTime() - math.max(held.l1, held.r1) > 2 then
    held.l1, held.r1 = nil, nil
    push("buttons")
  end
  if screens[s.name].update then screens[s.name].update(s) end
end

function love.draw()
  local sw, sh = love.graphics.getDimensions()
  local scale = math.min(sw / W, sh / H)
  love.graphics.push()
  love.graphics.translate((sw - W * scale) / 2, (sh - H * scale) / 2)
  love.graphics.scale(scale)
  setColor(C.bg)
  love.graphics.rectangle("fill", 0, 0, W, H)
  local s = top()
  screens[s.name].draw(s)
  if popup then drawPopup() end
  love.graphics.pop()
end

function love.quit()
  boostOff()
  pcall(stopBackground)
  if jobs then jobs:push({ kind = "quit" }) end
end

---------------------------------------------------------------- crash screen
-- LOVE's own error screen only closes with the Escape key, which the handheld
-- doesn't have. This one saves the error to log.txt and closes with any button.
function love.errorhandler(msg)
  msg = tostring(msg)
  local trace = debug.traceback("", 2)
  pcall(U.log, "CRASH: " .. msg .. "\n" .. tostring(trace))
  pcall(boostOff)
  pcall(stopBackground)
  if not U.isWindows then pcall(os.execute, "sync") end
  if jobs then pcall(function() jobs:push({ kind = "quit" }) end) end
  if not (love.window and love.graphics and love.event) then return end
  if not love.graphics.isCreated() or not love.window.isOpen() then
    if not pcall(love.window.setMode, 640, 480) then return end
  end
  love.graphics.reset()
  love.graphics.origin()
  local font = love.graphics.newFont(14)
  local text = "Pocket Drop hit a problem and needs to close.\n\n" .. msg
    .. "\n\nThe details were saved to log.txt in the PocketDrop folder.\n\nPress any button to exit."
  local shownAt = love.timer and love.timer.getTime() or 0
  return function()
    love.event.pump()
    for e in love.event.poll() do
      if e == "quit" then return 1 end
      local late = (not love.timer) or (love.timer.getTime() - shownAt > 0.7)
      if late and (e == "keypressed" or e == "gamepadpressed" or e == "joystickpressed") then return 1 end
    end
    love.graphics.clear(0.30, 0.06, 0.06)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font)
    local sw = love.graphics.getWidth()
    love.graphics.printf(text, 24, 24, math.min(sw, 640) - 48, "left")
    love.graphics.present()
    if love.timer then love.timer.sleep(0.05) end
  end
end
