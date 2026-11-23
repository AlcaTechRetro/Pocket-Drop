-- gdrive.lua
-- Google Drive support. Lists a shared folder with Google's official Drive API
-- (using your own API key) and builds direct download links for its files.
-- The folder must be shared as "Anyone with the link can view".

local J = require("json")

local G = {}

G.API = "https://www.googleapis.com/drive/v3/files"

-- Is this sites.ini address a Google Drive folder? Returns the folder id.
-- Accepts:  gdrive:FOLDER_ID
--           https://drive.google.com/drive/folders/FOLDER_ID?usp=sharing
--           https://drive.google.com/drive/u/0/folders/FOLDER_ID
--           https://drive.google.com/open?id=FOLDER_ID
function G.folderId(addr)
  if not addr then return nil end
  local id = addr:match("^gdrive:([%w_%-]+)")
  if id then return id end
  if addr:match("^https?://drive%.google%.com/") then
    return addr:match("/folders/([%w_%-]+)") or addr:match("[?&]id=([%w_%-]+)")
  end
  return nil
end

local function enc(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Address that lists one page of a folder's contents.
function G.listUrl(folderId, key, pageToken)
  local q = "'" .. folderId .. "' in parents and trashed=false"
  local url = G.API .. "?q=" .. enc(q)
    .. "&fields=" .. enc("nextPageToken,files(id,name,size,mimeType,md5Checksum)")
    .. "&pageSize=1000&supportsAllDrives=true&includeItemsFromAllDrives=true"
    .. "&key=" .. enc(key)
  if pageToken then url = url .. "&pageToken=" .. enc(pageToken) end
  return url
end

-- Address that asks about the folder itself (used to tell "empty" from
-- "not shared": Google answers 404 for a folder that isn't shared).
function G.metaUrl(folderId, key)
  return G.API .. "/" .. enc(folderId) .. "?fields=id%2Cname%2CmimeType&supportsAllDrives=true&key=" .. enc(key)
end

-- Folder id typed or pasted by the user: a full link or just the id.
function G.parseInput(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  return G.folderId(text) or (text:match("^[%w_%-]+$") and #text >= 10 and text) or nil
end

-- Direct download address for one file.
function G.downloadUrl(fileId, key)
  return G.API .. "/" .. enc(fileId) .. "?alt=media&supportsAllDrives=true&key=" .. enc(key)
end

local FOLDER = "application/vnd.google-apps.folder"

-- Read one page of Google's answer. Returns items, nextPageToken, skipped
-- (skipped = Google Docs/Sheets etc., which aren't real files and can't be
-- downloaded as-is).
function G.parseList(body, key, showHidden)
  local data, err = J.decode(body or "")
  if not data then return nil, nil, 0, err end
  if data.error then
    return nil, nil, 0, (data.error.message or "Google Drive error")
  end
  local items, skipped = {}, 0
  for _, f in ipairs(data.files or {}) do
    local name, mime = f.name or "?", f.mimeType or ""
    if showHidden or name:sub(1, 1) ~= "." then
      if mime == FOLDER then
        items[#items + 1] = { name = name, dir = true, url = "gdrive:" .. f.id }
      elseif mime:match("^application/vnd%.google%-apps%.") then
        skipped = skipped + 1
      else
        items[#items + 1] = { name = name, dir = false, url = G.downloadUrl(f.id, key),
          size = tonumber(f.size), md5 = f.md5Checksum }
      end
    end
  end
  return items, data.nextPageToken, skipped
end

-- Plain-English help for Google's error codes.
function G.explain(code, err)
  err = err or ""
  -- Reasons Google gives when it refuses to send a FILE (the folder list
  -- can still work fine).
  if err:find("downloadQuotaExceeded", 1, true) then
    return "Google has paused downloads of this file for now (download limit reached).\nThis happens after many downloads of the same file in a short time. It clears by itself, usually within 24 hours.\nTry again later. Other files may still work."
  elseif err:find("RateLimitExceeded", 1, true) or err:find("rateLimitExceeded", 1, true)
      or err:find("dailyLimitExceeded", 1, true) or err:find("429", 1, true) then
    return "Google says too many requests right now.\nWait a few minutes (or up to a day if it keeps happening) and try again."
  elseif err:find("cannotDownloadAbusiveFile", 1, true) then
    return "Google has blocked downloads of this file (it was flagged).\nOnly the file's owner can download it now, from the Drive website."
  elseif err:find("403", 1, true) and err:find(" - ", 1, true) then
    return "Google refused to send this file (403).\n\nGoogle's reason: " .. err:match(" %- (.*)$")
  end
  if err:find("400", 1, true) then
    return "Google says the API key is wrong.\nCheck api_key in sites.ini (it starts with AIza)."
  elseif err:find("403", 1, true) then
    return "Google refused the request (403).\nMake sure the Google Drive API is ENABLED in your Google Cloud project, and that the key isn't restricted to other APIs."
  elseif err:find("404", 1, true) then
    return "Folder not found (404).\nShare the folder as 'Anyone with the link - Viewer' and check the folder link in sites.ini."
  elseif err:find("429", 1, true) then
    return "Google says too many requests. Wait a minute and press Y."
  end
  return nil
end

return G
