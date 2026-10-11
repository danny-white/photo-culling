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

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrTasks           = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrFileUtils       = import 'LrFileUtils'
local LrPathUtils       = import 'LrPathUtils'

-- Move a fully-applied TSV into an 'applied/' sibling folder so it drops out of the file
-- picker's default view -- keeps you from accidentally re-picking (harmless, but pointless)
-- the same TSV next time, and keeps the inbox from growing unbounded as one-per-shoot TSVs
-- pile up. Copy via plain io (proven working -- same calls used to read the TSV), but delete
-- via LrFileUtils.delete: Lightroom's sandboxed Lua strips os.remove/os.rename/os.execute
-- entirely (calling them is "attempt to call field '...' (a nil value)", not a permission
-- error), so the SDK call is the only way to actually delete a file. Whole thing is
-- pcall-wrapped -- this step runs only after every photo's metadata is already written, so a
-- cleanup failure here must never surface as a hard "sync failed" error.
local function moveToApplied(path)
    local ok, result = LrTasks.pcall(function()
        local dir = LrPathUtils.parent(path)
        local appliedDir = LrPathUtils.child(dir, 'applied')
        LrFileUtils.createDirectory(appliedDir)
        local dest = LrPathUtils.child(appliedDir, LrPathUtils.leafName(path))
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

local BATCH_SIZE = 100  -- photos per write transaction; yield + update progress between batches
                        -- (the SDK disallows yielding while holding write access, so a batch
                        -- boundary is the only place progress can actually redraw)

local function shootFolderOf(photo)
    local path = photo:getRawMetadata('path') or ''
    local folder = path:match('([^/\\]+)[/\\][^/\\]+$')  -- parent directory name, / or \ separators
    return folder or ''
end

local function runSync(context)
    local catalog = LrApplication.activeCatalog()

    -- 1. The photos to update = current selection ("All Photographs" for a full-library sync).
    local photos = catalog:getTargetPhotos()
    if not photos or #photos == 0 then
        LrDialogs.message('AI Cull Sync', 'Select the photos to update first (e.g. All Photographs for a full sync).')
        return
    end

    -- 2. Choose the TSV produced by `export --plugin-data`. Defaults to the shared inbox folder
    -- on the passport drive itself (no network push needed -- the Mac mounts it directly).
    local inbox = '/Volumes/Passport/AICullInbox'
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

    -- 4. Apply in batches. ONLY label + keywords + caption -- never rating or flags. Keywords
    -- are created ONCE and cached by name -- calling catalog:createKeyword repeatedly for the
    -- same name within a single write transaction can hand back a stale/unusable reference on
    -- the 2nd+ call, which addKeyword then rejects; caching (and reusing across batches, which
    -- is safe -- keyword objects are catalog-level, not transaction-scoped) avoids that.
    local total = #photos
    local progress = LrProgressScope { title = 'Syncing AI Cull Data', functionContext = context }
    progress:setCancelable(true)

    local matched = 0
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

    local i = 1
    while i <= total do
        if progress:isCanceled() then break end
        local batchEnd = math.min(i + BATCH_SIZE - 1, total)

        catalog:withWriteAccessDo('Sync AI Cull Data', function()
            for idx = i, batchEnd do
                local photo = photos[idx]
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
        end, { timeout = 60 })

        progress:setPortionComplete(batchEnd, total)
        progress:setCaption(string.format('%d / %d photos (%d matched)', batchEnd, total, matched))
        LrTasks.yield()  -- only safe between batches, outside write access

        i = batchEnd + 1
    end

    progress:done()

    if progress:isCanceled() then
        LrDialogs.message(
            'AI Cull Sync canceled',
            string.format('Stopped after %d of %d photo(s); %d matched so far. Already-applied '
                .. 'changes were kept -- re-run to pick up where this left off.\n\n'
                .. 'The source TSV was left in place (not moved to applied/) since this run '
                .. 'didn\'t finish.', i - 1, total, matched))
    else
        -- Only move on a full, uncanceled pass -- a canceled run may not have covered every
        -- matching photo, so the TSV should stay available to re-run.
        local moved, moveInfo = moveToApplied(chosen[1])
        local moveNote = moved and ('\n\nSource TSV moved to applied/.')
            or ('\n\n(Could not move the source TSV to applied/: ' .. tostring(moveInfo) .. ' -- '
                .. 'the sync itself still succeeded.)')
        LrDialogs.message(
            'AI Cull Sync complete',
            string.format(
                '%d selected photo(s); %d matched the data file.\n' ..
                'Applied AI color label + keywords + caption. Your ratings and flags were not touched.%s',
                total, matched, moveNote))
    end
end

LrFunctionContext.postAsyncTaskWithContext('AICullSync', function(context)
    local ok, errOrResult = LrTasks.pcall(runSync, context)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Something went wrong:\n\n' .. tostring(errOrResult), 'critical')
    end
end)
