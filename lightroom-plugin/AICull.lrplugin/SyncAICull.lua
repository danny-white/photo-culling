--[[
  Sync AI Cull Data.

  Reads the TSV from `photo_cull.py export --plugin-data …` and applies, to the SELECTED photos,
  the AI color label + keywords. It only ever calls photo:setRawMetadata('label', …) and
  photo:addKeyword(…) -- it NEVER writes 'rating' or the pick/reject flag, so your own picks and
  star ratings are left exactly as they are.

  Match is by file name, so select one shoot at a time (file names can repeat across shoots).
]]

local LrApplication = import 'LrApplication'
local LrDialogs     = import 'LrDialogs'
local LrTasks       = import 'LrTasks'

local function runSync()
    local catalog = LrApplication.activeCatalog()

    -- 1. The photos to update = current selection (select a shoot first).
    local photos = catalog:getTargetPhotos()
    if not photos or #photos == 0 then
        LrDialogs.message('AI Cull Sync', 'Select the photos to update first (one shoot at a time).')
        return
    end

    -- 2. Choose the TSV produced by `export --plugin-data`.
    local chosen = LrDialogs.runOpenPanel {
        title                   = 'Choose AI cull data (.tsv)',
        canChooseFiles          = true,
        canChooseDirectories    = false,
        allowsMultipleSelection = false,
    }
    if not chosen or #chosen == 0 then return end

    -- 3. Parse it:  filename \t label \t kw1|kw2|...
    local byName = {}
    local fh, openErr = io.open(chosen[1], 'r')
    if not fh then
        LrDialogs.message('AI Cull Sync', 'Could not open file: ' .. tostring(openErr))
        return
    end
    for line in fh:lines() do
        line = line:gsub('\r$', '')  -- tolerate CRLF (file may have crossed from Windows/scp)
        local fname, label, kwstr = line:match('^([^\t]*)\t([^\t]*)\t(.*)$')
        if fname and fname ~= '' then
            local kws = {}
            for kw in (kwstr or ''):gmatch('[^|]+') do
                kws[#kws + 1] = kw
            end
            byName[fname] = { label = label:lower(), keywords = kws }
        end
    end
    fh:close()

    -- 4. Apply in one write transaction. ONLY label + keywords -- never rating or flags.
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
            local rec = byName[fname]
            if rec then
                matched = matched + 1
                if rec.label and rec.label ~= '' then
                    local lok, lerr = LrTasks.pcall(function() photo:setRawMetadata('label', rec.label) end)
                    if not lok then
                        error(string.format('setRawMetadata(label=%q) on %s: %s', rec.label, fname, tostring(lerr)))
                    end
                end
                for _, kw in ipairs(rec.keywords) do
                    if kw ~= '' then
                        local aok, aerr = LrTasks.pcall(function() photo:addKeyword(keywordFor(kw)) end)
                        if not aok then
                            error(string.format('addKeyword(%q) on %s: %s', kw, fname, tostring(aerr)))
                        end
                    end
                end
            end
        end
    end, { timeout = 120 })

    LrDialogs.message(
        'AI Cull Sync complete',
        string.format(
            '%d selected photo(s); %d matched the data file.\n' ..
            'Applied AI color label + keywords. Your ratings and flags were not touched.',
            #photos, matched))
end

LrTasks.startAsyncTask(function()
    local ok, errOrResult = LrTasks.pcall(runSync)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Something went wrong:\n\n' .. tostring(errOrResult), 'critical')
    end
end)
