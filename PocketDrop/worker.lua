-- worker.lua
-- Runs in a background thread. It does the slow network work (reading a
-- folder page, downloading a file, unzipping) so the screen never freezes.
-- The main program sends jobs on channel "rl_jobs" and reads answers on
-- channel "rl_results".

pcall(require, "love.timer")
local jobs = love.thread.getChannel("rl_jobs")
local results = love.thread.getChannel("rl_results")

local function quote(s, win)
  s = tostring(s)
  if win then return '"' .. (s:gsub('"', '')) .. '"' end
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Run a shell command and return its exit code (0 = success).
-- Input comes from "nothing" (/dev/null), so no program can ever stop and wait
-- for an answer (e.g. unzip asking "replace file?") - that froze downloads.
local function run(cmd, win)
  if not win then cmd = "{ " .. cmd .. "\n} < /dev/null" end
  local a, _, c = os.execute(cmd)
  local code
  if type(a) == "number" then code = a
  elseif a == true then code = 0
  else code = tonumber(c) or 1 end
  -- On Linux the raw status is "exit code x 256"; turn it back into the exit code.
  if not win and code > 255 then code = math.floor(code / 256) end
  return code
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function firstLine(path)
  local d = readAll(path)
  if not d then return "" end
  return (d:match("([^\r\n]+)") or "")
end

-- Ask the system to write everything to the SD card now, so turning the
-- console off afterwards can't damage files.
local function sync(win)
  if not win then os.execute("sync") end
end

-- Pause the worker (it runs in its own thread, so the screen keeps going).
local function pause(seconds)
  if love.timer and love.timer.sleep then love.timer.sleep(seconds) else os.execute("sleep " .. seconds) end
end

-- A tiny script that writes its own process number, then becomes the command
-- (exec). So the number saved is the download's own, and Stop can end it.
-- IMPORTANT: we never use the shell's "wait" command. In this background thread
-- some system signals are blocked, and BusyBox's "wait" then never wakes up
-- (that was the cause of downloads hanging at the end on muOS).
local helperPath
local function helper(tmp)
  if not helperPath then
    helperPath = tmp .. "/run-recording-pid.sh"
    local f = io.open(helperPath, "wb")
    f:write('#!/bin/sh\necho $$ >> "$1"\nshift\nexec "$@"\n')
    f:close()
  end
  return helperPath
end

local function log(msg)
  -- hide API keys in the log
  msg = msg:gsub("([?&]key=)[^&'\"%s]+", "%1***")
  results:push({ kind = "log", msg = "[worker] " .. msg })
end

local function nullDev(win) return win and "nul" or "/dev/null" end

-- Fetch a page into a file. Returns exit code.
local function fetch(job, url, out, err)
  local q = function(s) return quote(s, job.win) end
  local cmd
  if job.tool == "wget" then
    cmd = "wget -q -T 30 -O " .. q(out) .. " " .. q(url) .. " 2>" .. q(err)
  else
    -- -w prints the page's final address (after any redirect) into job.eff
    cmd = "curl -L --fail -sS --ipv4 --connect-timeout 20 --max-time 120 -o " .. q(out)
      .. " -w " .. q("%{url_effective}") .. " " .. q(url) .. " >" .. q(job.tmp .. "/page.eff") .. " 2>" .. q(err)
  end
  log(cmd)
  return run(cmd, job.win)
end

-- Ask the server how big the file is (may fail; that's fine). Only a final
-- "200 OK" answer counts: redirects and error pages report their own sizes,
-- which made the progress bar show 100% too early.
local function getSize(job)
  if job.tool ~= "curl" then return 0 end
  local hdr = job.tmp .. "/headers.txt"
  local cmd = "curl -sIL --ipv4 --connect-timeout 15 --max-time 30 -o " .. quote(hdr, job.win)
    .. " " .. quote(job.url, job.win) .. " 2>" .. nullDev(job.win)
  run(cmd, job.win)
  local text = readAll(hdr) or ""
  os.remove(hdr)
  -- headers of the last response only (after any redirects)
  local last = text
  for block in text:gmatch("HTTP/[%d%.]+%s+%d+[^\n]*\n.-\r?\n\r?\n") do last = block end
  local status = tonumber(last:match("HTTP/[%d%.]+%s+(%d+)") or 0)
  if status ~= 200 then return 0 end
  return tonumber(last:match("[Cc]ontent%-[Ll]ength:%s*(%d+)") or 0) or 0
end

local function doFetch(job)
  local out = job.tmp .. "/page.html"
  local err = job.tmp .. "/page.err"
  os.remove(out)
  local code = fetch(job, job.url, out, err)
  local body = readAll(out) or ""
  local eff = firstLine(job.tmp .. "/page.eff")
  results:push({ kind = "fetched", id = job.id, code = code, body = body, err = firstLine(err), eff = eff })
  os.remove(out)
  os.remove(job.tmp .. "/page.eff")
  os.remove(err)
end

local function fileSize(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end") or 0
  f:close()
  return n
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Connection problems worth retrying (the download then continues where it stopped):
-- 6 DNS, 7 connect, 18 partial file, 28 timeout/stalled, 35 TLS, 52 empty reply,
-- 55 send error, 56 receive error, 92 HTTP/2 stream error. (wget: 4 = network failure)
local RETRY = { [6] = true, [7] = true, [18] = true, [28] = true, [35] = true, [52] = true,
  [55] = true, [56] = true, [92] = true }
local MAX_TRIES = 6

-- After the whole file is in job.part: move it into place and unzip.
local function finish(job)
  local q = function(s) return quote(s, job.win) end
  local err = job.tmp .. "/dl.err"
  -- Compare with the fingerprint Google Drive / Internet Archive publish.
  if job.md5 and job.md5 ~= "" and not job.win then
    results:push({ kind = "status", id = job.id, text = "Checking the file..." })
    local out = job.tmp .. "/md5.txt"
    run("md5sum " .. q(job.part) .. " > " .. q(out) .. " 2>/dev/null", false)
    local got = ((readAll(out) or ""):match("^(%x+)") or ""):lower()
    os.remove(out)
    if got == "" then
      log("md5sum not available: skipping the check")
    elseif got ~= job.md5:lower() then
      log("checksum mismatch: expected " .. job.md5 .. " got " .. got .. " - deleting the damaged download")
      os.remove(job.part)
      sync(false)
      results:push({ kind = "done", id = job.id, ok = false, stage = "verify", code = -1,
        err = "The downloaded file was damaged (checksum mismatch) and was deleted. Please download it again." })
      return
    else
      log("checksum OK")
    end
  end
  local isZip = job.unzip and job.final:lower():match("%.zip$")
  if job.ram then
    -- The file is complete and checked in memory: now write it to the SD card
    -- in one go. A .zip is unpacked straight from memory onto the card.
    if isZip then
      results:push({ kind = "status", id = job.id, text = "Unzipping to the SD card..." })
      local t0 = os.time()
      local ucode = run("yes A 2>/dev/null | unzip -o -q " .. q(job.part) .. " -d " .. q(job.dir) .. " >/dev/null 2>" .. q(err), false)
      log("unzip finished with code " .. ucode .. " after " .. (os.time() - t0) .. "s")
      if ucode ~= 0 then
        os.remove(job.part)
        sync(false)
        results:push({ kind = "done", id = job.id, ok = false, stage = "unzip", code = ucode, err = firstLine(err) })
        return
      end
      if not job.delzip then run("cp " .. q(job.part) .. " " .. q(job.final), false) end
      os.remove(job.part)
      sync(false)
      log("download complete (saved to the SD card)")
      results:push({ kind = "done", id = job.id, ok = true })
      return
    end
    results:push({ kind = "status", id = job.id, text = "Saving to the SD card..." })
    local tmpFinal = job.final .. ".saving"
    local code = run("cp " .. q(job.part) .. " " .. q(tmpFinal) .. " 2>" .. q(err), false)
    if code ~= 0 or fileSize(tmpFinal) ~= fileSize(job.part) then
      local why = firstLine(err)
      log("copy to the SD card failed (code " .. code .. "): " .. why)
      os.remove(tmpFinal)
      os.remove(job.part)
      -- Find out why: card switched to read-only (file system errors) or full?
      local mounts = readAll("/proc/mounts") or ""
      -- the mount that holds the ROMS folder is the longest one matching its path
      local best, bestOpts, bestLine = "", nil, nil
      for line in mounts:gmatch("[^\n]+") do
        local mnt, opts = line:match("^%S+%s+(%S+)%s+%S+%s+(%S+)")
        if mnt and #mnt > #best and (job.dir == mnt or job.dir:sub(1, #mnt + 1) == mnt .. "/" or mnt == "/") then
          best, bestOpts, bestLine = mnt, opts, line
        end
      end
      local readonly = bestOpts ~= nil and (bestOpts == "ro" or bestOpts:sub(1, 3) == "ro,")
      if bestLine then log("card mount: " .. bestLine) end
      local dfout = job.tmp .. "/df.txt"
      run("df -k " .. q(job.dir) .. " > " .. q(dfout) .. " 2>/dev/null", false)
      local df = readAll(dfout) or ""
      os.remove(dfout)
      local freeKB = tonumber(df:match("\n%S+%s+%d+%s+%d+%s+(%d+)") or "")
      log("free space on the card: " .. tostring(freeKB) .. " KB; error: " .. why)
      local msg
      if readonly or why:lower():find("read%-only") then
        msg = "The SD card is READ-ONLY right now. The system does this when the card's file system has errors.\n\nRepair the card on a PC (Properties > Tools > Check, or chkdsk /f), or use SD card 2 (Settings > ROMS folder)."
      elseif freeKB and freeKB * 1024 < fileSize(job.part) + 1024 * 1024 then
        msg = "The SD card is full (" .. math.floor(freeKB / 1024) .. " MB free). Free some space and try again."
      else
        msg = "Couldn't write the file to the SD card.\n\n" .. (why ~= "" and why or "Unknown error") .. "\n\nCheck the card on a PC for errors."
      end
      sync(false)
      results:push({ kind = "done", id = job.id, ok = false, stage = "save", code = 23, err = msg })
      return
    end
    sync(false)
    os.remove(job.final)
    os.rename(tmpFinal, job.final)
    os.remove(job.part)
    sync(false)
    log("download complete (saved to the SD card)")
    results:push({ kind = "done", id = job.id, ok = true })
    return
  end

  log("moving the finished file into place")
  os.remove(job.final)
  if not os.rename(job.part, job.final) then
    results:push({ kind = "done", id = job.id, ok = false, stage = "save", code = -1, err = "could not rename file" })
    return
  end
  if job.partdir then os.remove(job.partdir) end   -- removes the .partial folder only if it's empty

  if isZip then
    results:push({ kind = "status", id = job.id, text = "Unzipping..." })
    local ucmd
    if job.win then
      ucmd = "tar -xf " .. q(job.final) .. " -C " .. q(job.dir) .. " 2>" .. q(err)
    else
      -- If unzip still asks "replace file?", answer "A" (replace All) automatically.
      ucmd = "yes A 2>/dev/null | unzip -o -q " .. q(job.final) .. " -d " .. q(job.dir) .. " >/dev/null 2>" .. q(err)
    end
    log(ucmd)
    local t0 = os.time()
    local ucode = run(ucmd, job.win)
    log("unzip finished with code " .. ucode .. " after " .. (os.time() - t0) .. "s")
    if ucode ~= 0 then
      results:push({ kind = "done", id = job.id, ok = false, stage = "unzip", code = ucode, err = firstLine(err) })
      os.remove(err)
      return
    end
    if job.delzip then os.remove(job.final) end
  end
  os.remove(err)
  sync(job.win)
  log("download complete (saved to the SD card)")
  results:push({ kind = "done", id = job.id, ok = true })
end

---------------------------------------------------------------- parallel download
-- Big files are fetched as several pieces at once. On weak Wi-Fi this is often
-- much faster than one connection. Piece 1 is written straight into job.part;
-- the others into job.part .. ".s2" etc., then appended to it (less copying).

-- Google (and some sites) explain a refusal in the reply body, e.g.
-- {"error":{"errors":[{"reason":"downloadQuotaExceeded",...}],"message":"..."}}
local function refusalReason(body)
  body = body or ""
  local reason = body:match('"reason"%s*:%s*"([^"]+)"')
  local msg = body:match('"message"%s*:%s*"([^"]+)"')
  if reason and msg then return reason .. ": " .. msg end
  return reason or msg or ""
end

-- Can the server send the file in pieces? "206" = yes, "200" = no (it sends
-- the whole file). 401/403/404/429 are a definite "no, you can't have it":
-- we stop at once (no point retrying or trying one connection) and keep the
-- server's reason for the error screen. Anything else (no answer, timeout) is
-- retried before we decide; if still unclear we use one connection.
-- Returns "yes", "no", "cancel" or "refused", code, reason.
local function rangeSupported(job)
  local out, body = job.tmp .. "/range.txt", job.tmp .. "/range.body"
  for attempt = 1, 3 do
    if exists(job.cancelflag) then return "cancel" end
    run("curl -sSL --ipv4 --connect-timeout 6 --max-time 8 -r 0-0 -o " .. quote(body, false)
      .. " -w '%{http_code}' " .. quote(job.url, false) .. " > " .. quote(out, false) .. " 2>/dev/null", false)
    local code = (readAll(out) or ""):match("(%d%d%d)%s*$") or "none"
    local reason = refusalReason((readAll(body) or ""):sub(1, 4000))
    os.remove(out); os.remove(body)
    log("pieces check " .. attempt .. ": answer " .. code .. (reason ~= "" and (" (" .. reason .. ")") or ""))
    if code == "206" then return "yes" end
    if code == "200" then return "no" end
    if code == "401" or code == "403" or code == "404" or code == "429" then
      return "refused", code, reason
    end
    if exists(job.cancelflag) then return "cancel" end
    pause(1)
  end
  return "no"
end

-- Ask the server why it refused (curl --fail hides the reason).
local function askWhy(job)
  local body = job.tmp .. "/why.body"
  run("curl -sSL --ipv4 --connect-timeout 8 --max-time 12 -r 0-0 -o " .. quote(body, false) .. " "
    .. quote(job.url, false) .. " 2>/dev/null", false)
  local reason = refusalReason((readAll(body) or ""):sub(1, 4000))
  os.remove(body)
  return reason
end

local function segFile(job, i) return i == 1 and job.part or (job.part .. ".s" .. i) end

local function doParallel(job, n)
  local q = function(s) return quote(s, false) end
  local total = job.total
  local piece = math.floor(total / n)
  local segs = {}
  for i = 1, n do
    local a = (i - 1) * piece
    local b = (i == n) and (total - 1) or (i * piece - 1)
    segs[i] = { a = a, b = b, len = b - a + 1, file = segFile(job, i), err = job.tmp .. "/seg" .. i .. ".err", rc = job.tmp .. "/seg" .. i .. ".rc" }
  end
  local tries = 0
  while true do
    tries = tries + 1
    -- any piece bigger than it should be means the server ignored our range: unsafe
    for _, sg in ipairs(segs) do
      if fileSize(sg.file) > sg.len then
        log("piece too big - server ignored the range; using one connection")
        for i = 1, n do os.remove(segFile(job, i)) end
        return false
      end
    end
    -- Each connection is one plain download into its own "chunk" file. Every
    -- connection runs in its own little background shell that writes a result
    -- file when the download ends; this worker watches for those files itself.
    local parts, todo, running = {}, 0, {}
    for i, sg in ipairs(segs) do
      local have = fileSize(sg.file)
      sg.chunk = sg.file .. ".c"
      os.remove(sg.rc)
      if have < sg.len then
        todo = todo + 1
        running[#running + 1] = sg
        os.remove(sg.chunk)
        local curl = "curl -L --fail -sS --ipv4 --connect-timeout 20 --speed-limit 1024 --speed-time 15 -r "
          .. (sg.a + have) .. "-" .. sg.b .. " -o " .. q(sg.chunk) .. " " .. q(job.url)
        parts[#parts + 1] = "( sh " .. q(helper(job.tmp)) .. " " .. q(job.pidfile) .. " " .. curl .. " 2>" .. q(sg.err)
          .. " ; echo $? > " .. q(sg.rc) .. " ) > /dev/null 2>&1 &"
      end
    end
    if todo == 0 then break end
    results:push({ kind = "status", id = job.id, text = (tries == 1 and "" or "Reconnected - ")
      .. "Downloading with " .. todo .. " connection" .. (todo == 1 and "" or "s") .. (tries > 1 and (" (try " .. tries .. ")") or "") })
    os.remove(job.pidfile)
    log("parallel: " .. todo .. " pieces")
    run(table.concat(parts, " "), false)          -- returns at once
    -- watch until every connection has written its result
    local cancelSeen
    while true do
      local left = 0
      for _, sg in ipairs(running) do if not exists(sg.rc) then left = left + 1 end end
      if left == 0 then break end
      if exists(job.cancelflag) then
        cancelSeen = cancelSeen or os.time()
        if os.time() - cancelSeen > 5 then break end   -- don't wait for ever after Stop
      end
      pause(0.25)
    end
    os.remove(job.pidfile)
    for i, sg in ipairs(running) do
      local rc = (readAll(sg.rc) or "?"):match("%-?%d+") or "?"
      log("connection " .. i .. " ended (code " .. rc .. ")")
    end
    -- add each chunk to its piece (cut to the size still needed)
    for _, sg in ipairs(segs) do
      local csize = fileSize(sg.chunk)
      if csize > 0 then
        local need = sg.len - fileSize(sg.file)
        local take = math.min(csize, need)
        if take > 0 then run("head -c " .. take .. " " .. q(sg.chunk) .. " >> " .. q(sg.file), false) end
      end
      os.remove(sg.chunk)
    end
    if exists(job.cancelflag) then
      os.remove(job.cancelflag)
      sync(false)
      results:push({ kind = "done", id = job.id, ok = false, stage = "cancelled", code = 143 })
      return true
    end
    local done, worst, werr = true, 0, ""
    for _, sg in ipairs(segs) do
      if fileSize(sg.file) < sg.len then
        done = false
        local rc = tonumber((readAll(sg.rc) or ""):match("%d+") or "1") or 1
        if rc ~= 0 then worst, werr = rc, firstLine(sg.err) end
      end
    end
    if done then break end
    local missing = 0
    for _, sg in ipairs(segs) do if fileSize(sg.file) < sg.len then missing = missing + (sg.len - fileSize(sg.file)) end end
    log("pieces incomplete: " .. missing .. " bytes still missing")
    local permanent = werr:find("404", 1, true) or werr:find("403", 1, true) or werr:find("401", 1, true)
    if permanent or tries >= MAX_TRIES then
      local kept = 0
      for _, sg in ipairs(segs) do kept = kept + fileSize(sg.file) end
      results:push({ kind = "done", id = job.id, ok = false, stage = "download", code = worst ~= 0 and worst or 18, err = werr, kept = kept })
      return true
    end
    log("pieces incomplete (code " .. worst .. "): " .. werr .. " - retrying")
    os.execute("sleep 3")
  end
  -- join the pieces onto piece 1
  log("all pieces downloaded; joining")
  results:push({ kind = "status", id = job.id, text = "Joining the pieces..." })
  if n > 1 then
    local list = {}
    for i = 2, n do list[#list + 1] = q(segFile(job, i)) end
    local code = run("cat " .. table.concat(list, " ") .. " >> " .. q(job.part), false)
    if code ~= 0 or fileSize(job.part) ~= total then
      results:push({ kind = "done", id = job.id, ok = false, stage = "save", code = 23, err = "could not join the pieces" })
      return true
    end
    for i = 2, n do os.remove(segFile(job, i)) end
  end
  for i = 1, n do os.remove(job.tmp .. "/seg" .. i .. ".rc"); os.remove(job.tmp .. "/seg" .. i .. ".err") end
  finish(job)
  return true
end

local function doDownload(job)
  local q = function(s) return quote(s, job.win) end
  local err = job.tmp .. "/dl.err"
  if exists(job.cancelflag) then
    -- cancelled before it even started
    os.remove(job.cancelflag)
    results:push({ kind = "done", id = job.id, ok = false, stage = "cancelled", code = 143 })
    return
  end
  -- Size from the folder listing (Drive / archive.org) is reliable; only ask
  -- the server when it's unknown.
  if not job.total or job.total <= 0 then
    local headSize = getSize(job)
    if headSize > 0 then job.total = headSize end
    results:push({ kind = "total", id = job.id, total = headSize })
  end

  -- Several connections at once for big files, when the server allows it.
  local n = tonumber(job.connections or 1) or 1
  for i = 8, 2, -1 do if exists(segFile(job, i)) then n = math.max(n, i) break end end   -- resume earlier pieces
  local singleStarted = fileSize(job.part) > 0 and not exists(segFile(job, 2))
  if n > 1 and not job.win and job.tool == "curl" and (job.total or 0) >= 4 * 1024 * 1024
    and not (singleStarted and fileSize(job.part) > math.floor(job.total / n)) then
    local answer, rcode, reason = "yes"
    if not exists(segFile(job, 2)) then answer, rcode, reason = rangeSupported(job) end
    if answer == "cancel" then
      os.remove(job.cancelflag)
      results:push({ kind = "done", id = job.id, ok = false, stage = "cancelled", code = 143 })
      return
    elseif answer == "refused" then
      log("server refused the file (" .. rcode .. "): " .. (reason ~= "" and reason or "no reason given"))
      results:push({ kind = "done", id = job.id, ok = false, stage = "download", code = 22,
        err = "The requested URL returned error: " .. rcode .. (reason ~= "" and (" - " .. reason) or ""), kept = 0 })
      return
    elseif answer == "yes" then
      if doParallel(job, n) then return end
    else
      log("server doesn't allow pieces: using one connection")
    end
  end

  local tries, code = 0, 1
  while true do
    tries = tries + 1
    local have = fileSize(job.part)
    if have > 0 then
      log("resuming from " .. have .. " bytes (try " .. tries .. ")")
      results:push({ kind = "status", id = job.id, text = tries == 1 and "Resuming..." or ("Reconnected - resuming (try " .. tries .. " of " .. MAX_TRIES .. ")") })
    elseif tries > 1 then
      results:push({ kind = "status", id = job.id, text = "Reconnecting (try " .. tries .. " of " .. MAX_TRIES .. ")" })
    end
    local cmd
    if job.tool == "wget" then
      cmd = "wget -q -c -T 30 -O " .. q(job.part) .. " " .. q(job.url) .. " 2>" .. q(err)
    else
      -- -C - continues a partial file; --speed-limit/--speed-time give up on a
      -- transfer stuck below 1 KB/s for 15 s (then we retry and resume).
      cmd = "curl -L --fail -sS --ipv4 --connect-timeout 20 --speed-limit 1024 --speed-time 15"
        .. (have > 0 and " -C -" or "") .. " -o " .. q(job.part) .. " " .. q(job.url) .. " 2>" .. q(err)
    end
    if not job.win then
      -- The helper saves the download's process number (so B can stop it) and
      -- the shell simply waits for it in the foreground - no "wait" command.
      os.remove(job.pidfile)
      cmd = "sh " .. q(helper(job.tmp)) .. " " .. q(job.pidfile) .. " " .. cmd
    end
    log(cmd)
    code = run(cmd, job.win)
    os.remove(job.pidfile)
    local e = firstLine(err)

    if code == 0 then break end
    if exists(job.cancelflag) then
      os.remove(job.cancelflag)
      os.remove(err)
      sync(job.win)
      results:push({ kind = "done", id = job.id, ok = false, stage = "cancelled", code = code })
      return
    end
    if code == 33 or e:find("416", 1, true) then
      -- The server can't continue this file (or it's already complete).
      local total = job.total or 0
      if total > 0 and fileSize(job.part) >= total then
        log("partial file was already complete")
        code = 0
        break
      end
      log("server can't resume this file: starting over")
      os.remove(job.part)
    elseif not (RETRY[code] or (job.tool == "wget" and code == 4)) or tries >= MAX_TRIES then
      -- A real error (e.g. file missing), or out of retries. Keep what was
      -- downloaded unless the file doesn't exist on the server any more.
      if e:find("404", 1, true) or e:find("403", 1, true) or e:find("401", 1, true) or e:find("429", 1, true) then
        os.remove(job.part)
        if not job.win then
          local why = askWhy(job)
          if why ~= "" then e = e .. " - " .. why; log("server's reason: " .. why) end
        end
      end
      results:push({ kind = "done", id = job.id, ok = false, stage = "download", code = code, err = e,
        kept = fileSize(job.part) })
      os.remove(err)
      return
    else
      log("connection problem (code " .. code .. "): " .. e .. " - retrying")
      if job.win then os.execute("ping -n 4 127.0.0.1 >nul") else os.execute("sleep 3") end
    end
  end

  if code ~= 0 then
    results:push({ kind = "done", id = job.id, ok = false, stage = "download", code = code, err = firstLine(err), kept = fileSize(job.part) })
    return
  end

  finish(job)
end

while true do
  local job = jobs:demand()
  if job.kind == "quit" then break end
  local ok, e = pcall(function()
    if job.kind == "fetch" then doFetch(job)
    elseif job.kind == "download" then doDownload(job) end
  end)
  if not ok then
    results:push({ kind = (job.kind == "fetch") and "fetched" or "done", id = job.id, ok = false,
      stage = "worker", code = -1, body = "", err = tostring(e) })
  end
end
