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

LrTasks.startAsyncTask(function()
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
    local fh, err = io.open(chosen[1], 'r')
    if not fh then
        LrDialogs.message('AI Cull Sync', 'Could not open file: ' .. tostring(err))
        return
    end
    for line in fh:lines() do
        local fname, label, kwstr = line:match('^([^\t]*)\t([^\t]*)\t(.*)$')
        if fname and fname ~= '' then
            local kws = {}
            for kw in (kwstr or ''):gmatch('[^|]+') do
                kws[#kws + 1] = kw
            end
            byName[fname] = { label = label, keywords = kws }
        end
    end
    fh:close()

    -- 4. Apply in one write transaction. ONLY label + keywords -- never rating or flags.
    local matched = 0
    catalog:withWriteAccessDo('Sync AI Cull Data', function()
        for _, photo in ipairs(photos) do
            local rec = byName[photo:getFormattedMetadata('fileName')]
            if rec then
                matched = matched + 1
                if rec.label and rec.label ~= '' then
                    photo:setRawMetadata('label', rec.label)          -- color = AI verdict
                end
                for _, kw in ipairs(rec.keywords) do
                    photo:addKeyword(catalog:createKeyword(kw, {}, true, nil, true))
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
end)
