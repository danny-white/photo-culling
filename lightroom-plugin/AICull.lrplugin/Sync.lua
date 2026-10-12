--[[
  The sync itself (v2.1), shared by the menu item (SyncAICull.lua: the selected photos and a file
  you pick) and the launch offer (Startup.lua: the photos of the shoots the waiting rows name,
  after you say yes).

  Applies up to two files from the AICullInbox to a set of photos (from the menu, the SELECTED
  photos: "All Photographs" for a full sync):

      pending.tsv         the AI's keywords and caption (never a colour label: v2.2)
                          (photo_cull.py export --plugin-data)
      cull-decisions.tsv  your phone culls: pick/reject flags, stars, burst notes
                          (Culling Bay Mobile's Send)

  Pick either file in the dialog; the other is applied in the same pass when it sits in the same
  folder. Match is by (shoot folder name, file name), not file name alone -- Sony resets its file
  counter across shoots, so one file can safely cover the whole library.

  What it will and won't overwrite (the rules live in CullCore.lua, which has unit tests):
    * Flags and stars: set only on a photo with none, or whose flag or stars this plugin set
      itself (remembered in hidden fields, AICullMetadata.lua). A flag or rating you set by hand
      is never changed; the photo is listed in the receipt instead.
    * Caption: the plugin owns two parts -- a first line starting "Burst reject · kept ", and the
      AI sentence it last wrote, remembered exactly. It replaces only those, so anything you typed
      stays. If you edit the AI's sentence, the caption becomes yours and the AI stops writing it.
    * Keywords: the AI's, applied as before.
    * Colour label: never set (v2.2). You stripped them all on 2026-10-11 and want none; the
      label column of pending.tsv, empty since then, is ignored even when an old file has one.

  After a complete (uncanceled) run it writes applied/<time>-receipt.tsv, one outcome per row,
  and applied/<time>-catalog.tsv, the flag and rating of every selected photo (so the phone can
  show what you already culled here). Culling Bay reads both back. Each input file moves to
  applied/<time>-<name>.
]]

local LrApplication     = import 'LrApplication'
local LrDate            = import 'LrDate'
local LrDialogs         = import 'LrDialogs'
local LrTasks           = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrFileUtils       = import 'LrFileUtils'
local LrPathUtils       = import 'LrPathUtils'

local Core = require 'CullCore'

local M = {}
M.INBOX               = '/Volumes/Passport/AICullInbox'
M.LAUNCH_DELAY        = 5    -- seconds after Lightroom starts before the launch offer looks
local COLLECTION_NAME = 'Burst rejects, similar kept'
local BATCH_SIZE      = 100  -- photos per write transaction; yield + update progress between batches
                             -- (the SDK disallows yielding while holding write access, so a batch
                             -- boundary is the only place progress can actually redraw)

-- Copy a fully-applied input into applied/ under a timestamped name, then delete the original.
-- Copy via plain io (the same calls that read it), delete via LrFileUtils.delete: Lightroom's
-- sandboxed Lua strips os.remove/os.rename entirely. Runs only after every photo is written, so a
-- failure here must never surface as a failed sync.
local function moveToApplied(path, stamp)
    local ok, result = LrTasks.pcall(function()
        local appliedDir = LrPathUtils.child(LrPathUtils.parent(path), 'applied')
        LrFileUtils.createDirectory(appliedDir)
        local dest = LrPathUtils.child(appliedDir, stamp .. '-' .. LrPathUtils.leafName(path))
        local src, rerr = io.open(path, 'rb')
        if not src then error('open source failed: ' .. tostring(rerr)) end
        local data = src:read('*a')
        src:close()
        local out, werr = io.open(dest, 'wb')
        if not out then error('open dest failed: ' .. tostring(werr)) end
        out:write(data)
        out:close()
        if not LrFileUtils.delete(path) then
            error('LrFileUtils.delete returned false for ' .. path)
        end
        return dest
    end)
    if not ok then return false, tostring(result) end
    return true, result
end

local function writeReceipt(dir, stamp, lines)
    local ok, result = LrTasks.pcall(function()
        local appliedDir = LrPathUtils.child(dir, 'applied')
        LrFileUtils.createDirectory(appliedDir)
        local dest = LrPathUtils.child(appliedDir, stamp .. '-receipt.tsv')
        local out, werr = io.open(dest, 'wb')
        if not out then error('open receipt failed: ' .. tostring(werr)) end
        out:write(Core.RECEIPT_HEADER, '\n', table.concat(lines, '\n'), #lines > 0 and '\n' or '')
        out:close()
        return dest
    end)
    if not ok then return false, tostring(result) end
    return true, result
end

-- What Lightroom holds for every selected photo after the sync, for Culling Bay: which photos
-- you have already flagged or rated there, so the phone can skip them. Virtual copies share their
-- master's file and are left out.
local function writeCatalog(catalog, photos, dir, stamp)
    local ok, result = LrTasks.pcall(function()
        local raw = catalog:batchGetRawMetadata(photos, { 'path', 'isVirtualCopy', 'pickStatus', 'rating' })
        local props = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, { 'cullFlag', 'cullStars' })
        local lines = { Core.CATALOG_HEADER }
        for _, photo in ipairs(photos) do
            local r, p = raw[photo] or {}, props[photo] or {}
            local folder, fname = (r.path or ''):match('([^/\\]+)[/\\]([^/\\]+)$')
            if folder and not r.isVirtualCopy then
                lines[#lines + 1] = Core.catalogLine(folder, fname, r.pickStatus, r.rating,
                    tonumber(p.cullFlag), tonumber(p.cullStars))
            end
        end
        local appliedDir = LrPathUtils.child(dir, 'applied')
        LrFileUtils.createDirectory(appliedDir)
        local dest = LrPathUtils.child(appliedDir, stamp .. '-catalog.tsv')
        local out, werr = io.open(dest, 'wb')
        if not out then error('open catalog file failed: ' .. tostring(werr)) end
        out:write(table.concat(lines, '\n'), '\n')
        out:close()
        return #lines - 1
    end)
    if not ok then return false, tostring(result) end
    return true, result
end

function M.readFile(path, parseLine)
    local fh, err = io.open(path, 'r')
    if not fh then error('Could not open ' .. path .. ': ' .. tostring(err)) end
    local byKey, n = {}, 0
    for line in fh:lines() do
        local key, rec = parseLine(line)
        if key then
            if not byKey[key] then n = n + 1 end
            byKey[key] = rec
        end
    end
    fh:close()
    return byKey, n
end

local function firstLineOf(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local line = fh:read('*l')
    fh:close()
    return line
end

-- Run fn and turn any error into one that names the photo, so a failed sync says where.
local function try(what, key, fn)
    local ok, err = LrTasks.pcall(fn)
    if not ok then error(string.format('%s on %s: %s', what, key, tostring(err))) end
end

-- opts.photos: the photos to update (default: the selection). opts.path: the input file (default:
-- ask with an open panel). opts.alone: apply just that file, not its partner in the same folder.
function M.run(context, opts)
    opts = opts or {}
    local catalog = LrApplication.activeCatalog()

    -- 1. The photos to update = current selection ("All Photographs" for a full-library sync).
    local photos = opts.photos or catalog:getTargetPhotos()
    if not photos or #photos == 0 then
        LrDialogs.message('AI Cull Sync', 'Select the photos to update first (e.g. All Photographs for a full sync).')
        return
    end

    -- 2. Choose an input; its partner in the same folder comes along.
    local chosen = opts.path and { opts.path } or LrDialogs.runOpenPanel {
        title                   = 'Choose AI cull data (pending.tsv or cull-decisions.tsv)',
        canChooseFiles          = true,
        canChooseDirectories    = false,
        allowsMultipleSelection = false,
        initialDirectory        = M.INBOX,
    }
    if not chosen or #chosen == 0 then return end
    local dir = LrPathUtils.parent(chosen[1])
    local aiPath, decPath
    if Core.isDecisionsHeader(firstLineOf(chosen[1])) then
        decPath = chosen[1]
        local p = LrPathUtils.child(dir, Core.AI_FILE)
        if not opts.alone and LrFileUtils.exists(p) == 'file' then aiPath = p end
    else
        aiPath = chosen[1]
        local p = LrPathUtils.child(dir, Core.DECISIONS_FILE)
        if not opts.alone and LrFileUtils.exists(p) == 'file' then decPath = p end
    end

    -- 3. Parse.
    local aiByKey, aiRows = {}, 0
    local decByKey, decRows = {}, 0
    if aiPath then aiByKey, aiRows = M.readFile(aiPath, Core.parseAILine) end
    if decPath then decByKey, decRows = M.readFile(decPath, Core.parseDecisionLine) end

    local progress = LrProgressScope { title = 'Syncing AI Cull Data', functionContext = context }
    progress:setCancelable(true)
    progress:setCaption('Reading the selected photos…')

    -- 4. Read what each photo has now, in bulk.
    local total = #photos
    local raw   = catalog:batchGetRawMetadata(photos, { 'path', 'isVirtualCopy' })
    local fmt   = catalog:batchGetFormattedMetadata(photos, { 'caption' })
    local props = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, { 'aiCaption' })
    local state = {}
    for idx, photo in ipairs(photos) do
        local path = (raw[photo] and raw[photo].path) or ''
        local folder, fname = path:match('([^/\\]+)[/\\]([^/\\]+)$')
        state[idx] = {
            key       = (folder or '') .. '/' .. (fname or ''),
            virtual   = raw[photo] and raw[photo].isVirtualCopy or false,
            caption   = (fmt[photo] and fmt[photo].caption) or '',
            aiCaption = props[photo] and props[photo].aiCaption or nil,
        }
    end

    -- 5. Captions this plugin has no record of writing that differ from the AI's new text. Until
    -- v2 the plugin overwrote Caption on every sync, so these are almost certainly older AI
    -- captions -- but text you typed would look the same. Ask once; the answer is remembered
    -- per photo, so the question doesn't come back.
    local unknown = 0
    for _, s in ipairs(state) do
        local ai = aiByKey[s.key]
        if ai and ai.caption ~= '' and s.aiCaption == nil then
            local _, _, status = Core.mergeCaption(s.caption, nil, ai.caption, nil, 'keep')
            if status == 'kept_unknown' then unknown = unknown + 1 end
        end
    end
    local firstSync = 'keep'
    if unknown > 0 then
        local answer = LrDialogs.confirm(
            string.format('%d caption(s) differ from the AI\'s new text', unknown),
            'This plugin has no record of writing these captions. Until now it overwrote Caption on '
                .. 'every sync, so they are most likely older AI captions, but anything you typed '
                .. 'yourself looks the same.\n\n'
                .. 'Keep: leave them, treat them as yours from now on, and list them in the receipt.\n'
                .. 'Replace: treat them as old AI captions and write the new AI text.',
            'Keep them', 'Cancel', 'Replace them')
        if answer == 'cancel' then
            progress:done()
            return
        end
        if answer == 'other' then firstSync = 'replace' end
    end

    -- 6. The burst-reject keyword and its smart collection, once.
    local burstKw, collectionNote
    if decRows > 0 then
        catalog:withWriteAccessDo('AI Cull: burst-reject keyword', function()
            local parent = catalog:createKeyword('Cull', {}, false, nil, true)
            burstKw = catalog:createKeyword('Burst reject', {}, true, parent, true)
        end, { timeout = 60 })
        local ok, err = LrTasks.pcall(function()
            catalog:withWriteAccessDo('AI Cull: burst-rejects collection', function()
                catalog:createSmartCollection(COLLECTION_NAME, {
                    { criteria = 'keywords', operation = 'words', value = 'Burst reject' },
                    { criteria = 'pick', operation = '==', value = -1 },
                    combine = 'intersect',
                }, nil, true)
            end, { timeout = 60 })
        end)
        if not ok then collectionNote = 'Could not create the "' .. COLLECTION_NAME .. '" smart collection: ' .. tostring(err) end
    end

    -- 7. Apply in batches. Keywords are created ONCE and cached by name: calling createKeyword
    -- repeatedly for the same name within one write transaction can hand back a stale reference
    -- that addKeyword then rejects. Keyword objects are catalog-level, so the cache is safe
    -- across batches.
    local keywordCache = {}
    local function keywordFor(kw)
        if not keywordCache[kw] then
            keywordCache[kw] = catalog:createKeyword(kw, {}, true, nil, true)
        end
        return keywordCache[kw]
    end

    local receipt = {}
    local seenDec = {}
    local counts = { ai = 0, dec = 0, flags = 0, flagKept = 0, starsKept = 0, captionLeft = 0 }

    local function applyOne(photo, s, ai, dec)
        local folder, fname = s.key:match('^([^/]*)/(.*)$')
        if ai then
            counts.ai = counts.ai + 1
            for _, kw in ipairs(ai.keywords) do
                if kw ~= '' then
                    try(string.format('addKeyword(%q)', kw), s.key, function() photo:addKeyword(keywordFor(kw)) end)
                end
            end
        end

        -- Phone decision: flag first, because a flag you set by hand also keeps the burst note
        -- and keyword off the photo. Virtual copies share their master's file, so they are skipped.
        local useDec = dec and not s.virtual
        local fa, sa, flagNow, starsNow
        if useDec then
            counts.dec = counts.dec + 1
            seenDec[s.key] = true
            local mineFlag, mineStars
            try('read flag and rating', s.key, function()
                flagNow = photo:getRawMetadata('pickStatus')
                starsNow = photo:getRawMetadata('rating')
                mineFlag = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'cullFlag'))
                mineStars = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'cullStars'))
            end)
            local fm, sm
            fa, fm = Core.decideFlag(flagNow, mineFlag, dec.pick)
            if fa == 'set' then
                try('setRawMetadata(pickStatus)', s.key, function() photo:setRawMetadata('pickStatus', dec.pick) end)
                counts.flags = counts.flags + 1
            end
            if fm ~= mineFlag then
                try('setPropertyForPlugin(cullFlag)', s.key, function()
                    photo:setPropertyForPlugin(_PLUGIN, 'cullFlag', fm and tostring(fm) or nil)
                end)
            end
            sa, sm = Core.decideStars(starsNow, mineStars, dec.stars)
            if sa == 'set' then
                local value = (dec.stars or 0) > 0 and dec.stars or nil
                try('setRawMetadata(rating)', s.key, function() photo:setRawMetadata('rating', value) end)
            end
            if sm ~= mineStars then
                try('setPropertyForPlugin(cullStars)', s.key, function()
                    photo:setPropertyForPlugin(_PLUGIN, 'cullStars', sm and tostring(sm) or nil)
                end)
            end
            if burstKw and fa ~= 'kept' then
                if dec.note ~= '' then
                    try('addKeyword(Burst reject)', s.key, function() photo:addKeyword(burstKw) end)
                else
                    -- Non-fatal: most photos never had it, and a no-op removal must not stop the sync.
                    LrTasks.pcall(function() photo:removeKeyword(burstKw) end)
                end
            end
        end

        local note = (useDec and fa ~= 'kept') and dec.note or nil
        local newCap, store, status = Core.mergeCaption(
            s.caption, s.aiCaption, ai and ai.caption or nil, note, firstSync)
        if newCap ~= s.caption then
            try('setRawMetadata(caption)', s.key, function() photo:setRawMetadata('caption', newCap) end)
        end
        if store ~= s.aiCaption then
            try('setPropertyForPlugin(aiCaption)', s.key, function() photo:setPropertyForPlugin(_PLUGIN, 'aiCaption', store) end)
        end

        if status == 'kept_edited' or status == 'kept_unknown' then
            counts.captionLeft = counts.captionLeft + 1
            receipt[#receipt + 1] = Core.receiptLine(folder, fname, 'caption_left',
                status == 'kept_edited' and 'you edited the AI sentence' or 'caption not written by this plugin')
        end
        if not useDec then return end
        if fa == 'kept' then
            counts.flagKept = counts.flagKept + 1
            receipt[#receipt + 1] = Core.receiptLine(folder, fname, 'your_flag_kept',
                flagNow == 1 and 'you picked it' or 'you rejected it')
        else
            receipt[#receipt + 1] = Core.receiptLine(folder, fname, 'applied', dec.flag)
        end
        if sa == 'kept' then
            counts.starsKept = counts.starsKept + 1
            receipt[#receipt + 1] = Core.receiptLine(folder, fname, 'your_stars_kept',
                tostring(starsNow) .. ' stars')
        end
    end

    local i = 1
    while i <= total do
        if progress:isCanceled() then break end
        local batchEnd = math.min(i + BATCH_SIZE - 1, total)
        catalog:withWriteAccessDo('Sync AI Cull Data', function()
            for idx = i, batchEnd do
                local s = state[idx]
                local ai, dec = aiByKey[s.key], decByKey[s.key]
                if ai or dec then applyOne(photos[idx], s, ai, dec) end
            end
        end, { timeout = 60 })
        progress:setPortionComplete(batchEnd, total)
        progress:setCaption(string.format('%d / %d photos (%d AI, %d phone)', batchEnd, total, counts.ai, counts.dec))
        LrTasks.yield()  -- only safe between batches, outside write access
        i = batchEnd + 1
    end
    progress:done()

    local summary = string.format(
        '%d selected photo(s).\nAI data: %d row(s), applied to %d photo(s).\nPhone culls: %d row(s), '
            .. 'applied to %d photo(s); %d flag(s) set, %d of your flags kept, %d of your ratings kept.\n'
            .. 'Captions left as yours: %d.',
        total, aiRows, counts.ai, decRows, counts.dec, counts.flags, counts.flagKept, counts.starsKept,
        counts.captionLeft)
    if collectionNote then summary = summary .. '\n\n' .. collectionNote end

    if progress:isCanceled() then
        LrDialogs.message('AI Cull Sync canceled',
            summary .. '\n\nStopped after ' .. (i - 1) .. ' photo(s). Already-applied changes were '
                .. 'kept; the input files stay in place, so re-run to finish.')
        return
    end

    -- 8. Receipt (phone rows not found in the selection count as missing), then move the inputs.
    local missing = 0
    for key, dec in pairs(decByKey) do
        if not seenDec[key] then
            missing = missing + 1
            receipt[#receipt + 1] = Core.receiptLine(dec.folder, dec.fname, 'missing', 'not in the selection')
        end
    end
    local stamp = LrDate.timeToUserFormat(LrDate.currentTime(), '%Y%m%d-%H%M%S')
    local notes = {}
    if decPath or #receipt > 0 then
        local ok, info = writeReceipt(dir, stamp, receipt)
        notes[#notes + 1] = ok and ('Receipt: applied/' .. LrPathUtils.leafName(info))
            or ('Could not write the receipt: ' .. tostring(info))
    end
    local inputs = {}   -- not { aiPath, decPath }: ipairs stops at the first nil, so a missing
    if aiPath then inputs[#inputs + 1] = aiPath end      -- pending.tsv would skip the decisions file
    if decPath then inputs[#inputs + 1] = decPath end
    for _, path in ipairs(inputs) do
        local ok, info = moveToApplied(path, stamp)
        if not ok then
            notes[#notes + 1] = 'Could not move ' .. LrPathUtils.leafName(path) .. ' to applied/: ' .. tostring(info)
        end
    end
    if missing > 0 then
        notes[#notes + 1] = string.format('%d phone row(s) matched no selected photo; the receipt lists them.', missing)
    end
    local cok, cinfo = writeCatalog(catalog, photos, dir, stamp)
    notes[#notes + 1] = cok and string.format('Flags and ratings of %d photo(s) sent back to Culling Bay.', cinfo)
        or ('Could not write the catalog file for Culling Bay: ' .. tostring(cinfo))
    LrDialogs.message('AI Cull Sync complete', summary .. '\n\n' .. table.concat(notes, '\n'))
end

return M
