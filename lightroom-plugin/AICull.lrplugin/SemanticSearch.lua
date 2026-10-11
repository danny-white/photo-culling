--[[
  AI Semantic Search.

  Prompts for a text description, sends it to review/server.py's /api/semantic_search (embeds the
  query with the same model used to index every photo's caption/tags/scene, then cosine-KNN over
  those vectors), and drops the matches into a catalog collection named "AI Search Results",
  ranked best match first.

  Response format is TSV (?format=tsv), not JSON -- Lightroom's sandboxed Lua has no JSON decoder,
  and the server already speaks this exact shape (shootFolder \t filename \t ...) for the AI-Cull
  sync TSV, so reusing it here avoids vendoring a JSON parser for one field.

  Tries the LAN address first (fast on the home network), then falls back to Tailscale (works
  from anywhere, survives the LAN IP changing) -- this HTTP path has no precedent in this plugin
  (SyncAICull.lua only ever reads local/SMB-mounted files), so failures are reported plainly
  rather than silently swallowed.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrTasks           = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrView            = import 'LrView'
local LrBinding         = import 'LrBinding'
local LrHttp            = import 'LrHttp'
local LrStringUtils     = import 'LrStringUtils'

-- Same box, two paths in: fast on the home LAN, Tailscale as a fallback that works from anywhere
-- and survives the LAN IP changing (it's DHCP, not static).
local LAN_URL       = 'http://192.168.1.54:8000'
local TAILSCALE_URL = 'http://100.82.57.4:8000'
local LAN_TIMEOUT    = 2   -- seconds -- normal LAN round trip is well under 1s; fail fast
local TS_TIMEOUT      = 6   -- seconds -- VPN tunnel adds latency, worth waiting a bit longer

local function urlEncode(s)
    s = tostring(s or '')
    s = s:gsub('([^%w%-%.%_%~ ])', function(c) return string.format('%%%02X', string.byte(c)) end)
    s = s:gsub(' ', '+')
    return s
end

-- Try LAN, then Tailscale. Returns (body, "LAN"|"Tailscale") on success, (nil, nil) if both fail.
-- LrHttp.get's failure behavior (nil vs. thrown error) isn't guaranteed consistent across SDK
-- versions, so both are pcall-wrapped and either outcome is treated the same way: try the next one.
local function fetchTSV(query, k)
    local path = string.format('/api/semantic_search?q=%s&k=%d&format=tsv', urlEncode(query), k)
    local ok, body = LrTasks.pcall(LrHttp.get, LAN_URL .. path, nil, LAN_TIMEOUT)
    if ok and body and body ~= '' then return body, 'LAN' end
    local ok2, body2 = LrTasks.pcall(LrHttp.get, TAILSCALE_URL .. path, nil, TS_TIMEOUT)
    if ok2 and body2 and body2 ~= '' then return body2, 'Tailscale' end
    return nil, nil
end

-- The only error responses the server can return arrive as JSON (no embeddings indexed yet, the
-- embedding call itself failed, ...) even though ?format=tsv was requested -- those come back
-- from an early `return jsonify(...)` in server.py before the TSV branch runs. No JSON decoder
-- here either -- just pull out the one field this needs to show a useful message.
local function extractJsonError(body)
    return body and body:match('"error"%s*:%s*"(.-)"')
end

local function parseResults(tsv)
    local results = {}
    for line in tsv:gmatch('[^\r\n]+') do
        local folder, fname, score, caption = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
        if folder and fname and fname ~= '' then
            results[#results + 1] = { folder = folder, filename = fname,
                                      score = tonumber(score) or 0, caption = caption or '' }
        end
    end
    return results
end

-- Parent-directory-name match, same convention as SyncAICull.lua's shootFolderOf -- Sony resets
-- its file counter across shoots, so filename alone isn't a safe key.
local function shootFolderOf(photo)
    local path = photo:getRawMetadata('path') or ''
    local folder = path:match('([^/\\]+)[/\\][^/\\]+$')
    return folder or ''
end

local function buildCatalogIndex(catalog)
    local byKey = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        local fname = photo:getFormattedMetadata('fileName')
        byKey[shootFolderOf(photo) .. '/' .. fname] = photo
    end
    return byKey
end

local function runSearch(context)
    local catalog = LrApplication.activeCatalog()

    local props = LrBinding.makePropertyTable(context)
    props.query = ''
    local f = LrView.osFactory()
    local contents = f:column {
        bind_to_object = props,
        spacing = f:control_spacing(),
        f:static_text { title = "Describe what you're looking for:" },
        f:edit_field { value = LrView.bind('query'), width_in_chars = 44, immediate = true },
    }
    local result = LrDialogs.presentModalDialog {
        title = 'AI Semantic Search', contents = contents, actionVerb = 'Search',
    }
    if result ~= 'ok' then return end
    local query = LrStringUtils.trimWhitespace(props.query or '')
    if query == '' then
        LrDialogs.message('AI Semantic Search', 'Type a description first.')
        return
    end

    local progress = LrProgressScope { title = 'AI Semantic Search', functionContext = context }
    progress:setCaption('Searching…')
    local tsv, via = fetchTSV(query, 80)
    if not tsv then
        progress:done()
        LrDialogs.message('AI Semantic Search',
            'Could not reach the search server on the LAN or via Tailscale.\n\n'
            .. 'Check that review/server.py is running on the Linux box.', 'critical')
        return
    end
    local errMsg = extractJsonError(tsv)
    if errMsg then
        progress:done()
        LrDialogs.message('AI Semantic Search', 'Search server error: ' .. errMsg, 'critical')
        return
    end
    local results = parseResults(tsv)
    if #results == 0 then
        progress:done()
        LrDialogs.message('AI Semantic Search', string.format('No matches for "%s".', query))
        return
    end

    progress:setCaption('Matching to catalog…')
    local index = buildCatalogIndex(catalog)
    local ordered = {}
    for _, r in ipairs(results) do
        local photo = index[r.folder .. '/' .. r.filename]
        if photo then ordered[#ordered + 1] = photo end
    end
    progress:done()
    if #ordered == 0 then
        LrDialogs.message('AI Semantic Search',
            string.format('%d match(es) found, but none are in this catalog.', #results))
        return
    end

    -- createCollection must run inside write access -- do create + repopulate as one transaction
    -- so a mid-way failure can't leave the collection half-updated.
    local ok, err = LrTasks.pcall(function()
        catalog:withWriteAccessDo('AI Semantic Search Results', function()
            local collection = catalog:createCollection('AI Search Results', nil, true)
            collection:removeAllPhotos()
            collection:addPhotos(ordered)  -- insertion order = rank order (best match first)
        end, { timeout = 60 })
    end)
    if not ok then
        LrDialogs.message('AI Semantic Search',
            'Could not update the "AI Search Results" collection:\n\n' .. tostring(err), 'critical')
        return
    end
    LrTasks.pcall(function()
        catalog:setActiveSources({ catalog:createCollection('AI Search Results', nil, true) })
    end)

    LrDialogs.message('AI Semantic Search complete',
        string.format(
            '%d of %d match(es) found in your catalog (via %s).\n\n'
            .. '"AI Search Results" collection updated, ranked best match first -- if it doesn\'t '
            .. 'look ranked, right-click the grid and choose Sort > Custom Order.',
            #ordered, #results, via))
end

LrFunctionContext.postAsyncTaskWithContext('AISemanticSearch', function(context)
    local ok, errOrResult = LrTasks.pcall(runSearch, context)
    if not ok then
        LrDialogs.message('AI Semantic Search -- error', 'Something went wrong:\n\n' .. tostring(errOrResult), 'critical')
    end
end)
