--[[
  Sync AI Cull Data.

  Reads the TSV from `photo_cull.py export --plugin-data …` and applies, to the SELECTED photos,
  the AI color label + keywords + caption. It only ever calls photo:setRawMetadata('label', …),
  photo:setRawMetadata('caption', …), and photo:addKeyword(…) -- it NEVER writes 'rating' or the
  pick/reject flag, so your own picks and star ratings are left exactly as they are.

  Match is by (shoot folder name, file name), not file name alone -- Sony resets its file
  counter across shoots, so this TSV can safely cover the WHOLE library in one run. Select
  "All Photographs" (or any subset you like) before running.
]]

local LrApplication = import 'LrApplication'
local LrDialogs     = import 'LrDialogs'
local LrTasks       = import 'LrTasks'

local function shootFolderOf(photo)
    local path = photo:getRawMetadata('path') or ''
    local folder = path:match('([^/\\]+)[/\\][^/\\]+$')  -- parent directory name, / or \ separators
    return folder or ''
end

local function runSync()
    local catalog = LrApplication.activeCatalog()

    -- 1. The photos to update = current selection ("All Photographs" for a full-library sync).
    local photos = catalog:getTargetPhotos()
    if not photos or #photos == 0 then
        LrDialogs.message('AI Cull Sync', 'Select the photos to update first (e.g. All Photographs for a full sync).')
        return
    end

    -- 2. Choose the TSV produced by `export --plugin-data`. Defaults to the shared inbox folder.
    local inbox = (os.getenv('HOME') or '') .. '/AICullInbox'
    local chosen = LrDialogs.runOpenPanel {
        title                   = 'Choose AI cull data (.tsv)',
        canChooseFiles          = true,
        canChooseDirectories    = false,
        allowsMultipleSelection = false,
        initialDirectory        = inbox,
    }
    if not chosen or #chosen == 0 then return end

    -- 3. Parse it:  shootFolder \t filename \t label \t kw1|kw2|... \t caption
    local byKey = {}
    local fh, openErr = io.open(chosen[1], 'r')
    if not fh then
        LrDialogs.message('AI Cull Sync', 'Could not open file: ' .. tostring(openErr))
        return
    end
    for line in fh:lines() do
        line = line:gsub('\r$', '')  -- tolerate CRLF (file may have crossed from Windows/scp)
        local folder, fname, label, kwstr, caption =
            line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
        if folder and fname and fname ~= '' then
            local kws = {}
            for kw in (kwstr or ''):gmatch('[^|]+') do
                kws[#kws + 1] = kw
            end
            -- Keep the TSV's capitalized name as-is (e.g. "Yellow") -- Lightroom resolves the
            -- filterable color swatch by case-sensitive match against the active Label Set's
            -- display names; a lowercase value stores fine as text but never resolves to a color.
            byKey[folder .. '/' .. fname] = { label = label, keywords = kws, caption = caption or '' }
        end
    end
    fh:close()

    -- 4. Apply in one write transaction. ONLY label + keywords + caption -- never rating or flags.
    -- Keywords are created ONCE up front and cached by name -- calling catalog:createKeyword
    -- repeatedly for the same name (once per photo) can hand back a stale/unusable reference
    -- on the 2nd+ call within a single write transaction, which addKeyword then rejects.
    local matched = 0
    catalog:withWriteAccessDo('Sync AI Cull Data', function()
        local keywordCache = {}
        local function keywordFor(kw)
            if not keywordCache[kw] then
                local kok, keyword = LrTasks.pcall(function()
                    return catalog:createKeyword(kw, {}, true, nil, true)
                end)
                if not kok then
                    error(string.format('createKeyword(%q): %s', kw, tostring(keyword)))
                end
                keywordCache[kw] = keyword
            end
            return keywordCache[kw]
        end

        for _, photo in ipairs(photos) do
            local fname = photo:getFormattedMetadata('fileName')
            local key = shootFolderOf(photo) .. '/' .. fname
            local rec = byKey[key]
            if rec then
                matched = matched + 1
                if rec.label and rec.label ~= '' then
                    local lok, lerr = LrTasks.pcall(function() photo:setRawMetadata('label', rec.label) end)
                    if not lok then
                        error(string.format('setRawMetadata(label=%q) on %s: %s', rec.label, key, tostring(lerr)))
                    end
                end
                if rec.caption and rec.caption ~= '' then
                    local cok, cerr = LrTasks.pcall(function() photo:setRawMetadata('caption', rec.caption) end)
                    if not cok then
                        error(string.format('setRawMetadata(caption) on %s: %s', key, tostring(cerr)))
                    end
                end
                for _, kw in ipairs(rec.keywords) do
                    if kw ~= '' then
                        local aok, aerr = LrTasks.pcall(function() photo:addKeyword(keywordFor(kw)) end)
                        if not aok then
                            error(string.format('addKeyword(%q) on %s: %s', kw, key, tostring(aerr)))
                        end
                    end
                end
            end
        end
    end, { timeout = 300 })

    LrDialogs.message(
        'AI Cull Sync complete',
        string.format(
            '%d selected photo(s); %d matched the data file.\n' ..
            'Applied AI color label + keywords + caption. Your ratings and flags were not touched.',
            #photos, matched))
end

LrTasks.startAsyncTask(function()
    local ok, errOrResult = LrTasks.pcall(runSync)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Something went wrong:\n\n' .. tostring(errOrResult), 'critical')
    end
end)
