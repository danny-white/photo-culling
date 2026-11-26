--[[
  Pure logic for AI Cull Sync: parsing the three inbox files, merging Caption, deciding whether
  a flag or star rating may be written, and which People keywords to add or remove. No Lightroom
  imports, so it also runs under plain Lua 5.1 for the tests in
  lightroom-plugin/tests/test_cullcore.lua.
]]

local M = {}

M.AI_FILE          = 'pending.tsv'
M.DECISIONS_FILE   = 'cull-decisions.tsv'
M.DECISIONS_HEADER = '#cull-decisions v1'
M.RECEIPT_HEADER   = '#cull-receipt v1'
M.CATALOG_HEADER   = '#cull-catalog v1'
M.PEOPLE_FILE      = 'people.tsv'
M.PEOPLE_HEADER    = '#people v1'
M.PEOPLE_PARENT    = 'People'                       -- the keyword the named people go under
M.NOTE_PREFIX      = 'Burst reject \194\183 kept '   -- "Burst reject · kept " (UTF-8 middle dot)

-- Stored in the hidden aiCaption field once a caption is settled as yours (you kept it at the
-- first v2 sync, or edited the AI's sentence). The AI then never writes into it again, unless
-- you clear the caption.
M.YOURS = '[yours]'

local PICK = { pick = 1, reject = -1, none = 0 }

local function chomp(line)
    return (line:gsub('\r$', ''))
end

-- AI rows (photo_cull.py export --plugin-data):
--   shootFolder \t filename \t colorLabel \t kw1|kw2|... \t caption
-- colorLabel is parsed but never applied (v2.2: no colour labels in Lightroom).
function M.parseAILine(line)
    line = chomp(line)
    if line == '' or line:sub(1, 1) == '#' then return nil end
    local folder, fname, label, kwstr, caption =
        line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
    if not folder or fname == '' then return nil end
    local kws = {}
    for kw in kwstr:gmatch('[^|]+') do kws[#kws + 1] = kw end
    return folder .. '/' .. fname,
        { folder = folder, fname = fname, label = label, keywords = kws, caption = caption or '' }
end

-- Phone rows (Culling Bay Mobile's Send):
--   shootFolder \t filename \t pick|reject|none \t stars or empty \t note or empty
function M.parseDecisionLine(line)
    line = chomp(line)
    if line == '' or line:sub(1, 1) == '#' then return nil end
    local folder, fname, flag, stars, note =
        line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
    if not folder or fname == '' or PICK[flag] == nil then return nil end
    return folder .. '/' .. fname, {
        folder = folder, fname = fname, flag = flag, pick = PICK[flag],
        stars = tonumber(stars), note = note or '',
    }
end

function M.isDecisionsHeader(line)
    return line ~= nil and chomp(line) == M.DECISIONS_HEADER
end

function M.isPeopleHeader(line)
    return line ~= nil and chomp(line) == M.PEOPLE_HEADER
end

-- A set of names as a list: split on '|', trimmed, no empty names, one of each (case aside),
-- in the order given. nil or '' is the empty set.
function M.parsePeopleSet(str)
    local names, seen = {}, {}
    for name in (str or ''):gmatch('[^|]+') do
        name = name:match('^%s*(.-)%s*$')
        local lower = name:lower()
        if name ~= '' and not seen[lower] then
            seen[lower] = true
            names[#names + 1] = name
        end
    end
    return names
end

-- ... and back: the pipe-joined string kept in the hidden peopleSet field, names in alphabetical
-- order (case aside) so equal sets give equal strings. nil for the empty set, which clears the field.
function M.serializePeopleSet(names)
    local list = M.parsePeopleSet(table.concat(names or {}, '|'))
    if #list == 0 then return nil end
    table.sort(list, function(a, b)
        local x, y = a:lower(), b:lower()
        if x ~= y then return x < y end
        return a < b
    end)
    return table.concat(list, '|')
end

-- People rows (Culling Bay's people.tsv, review/people.py): the named people in each photo
--   shootFolder \t filename \t name1|name2|...
-- The names are empty when the last person was taken off the photo; the row stays so that the
-- keyword this plugin added can be removed.
function M.parsePeopleLine(line)
    line = chomp(line)
    if line == '' or line:sub(1, 1) == '#' then return nil end
    local folder, fname, namestr = line:match('^([^\t]*)\t([^\t]*)\t?([^\t]*)')
    if not folder or fname == '' then return nil end
    return folder .. '/' .. fname,
        { folder = folder, fname = fname, names = M.parsePeopleSet(namestr) }
end

local function lowerSet(names)
    local set = {}
    for _, name in ipairs(names or {}) do set[name:lower()] = true end
    return set
end

--[[
  peopleChanges(desired, previouslySet, current) -> add, remove   (all three are lists of names)

    desired        the names Culling Bay says are in the photo now
    previouslySet  the names this plugin set last time (the hidden peopleSet field)
    current        the names under People that the photo holds now

  add     desired names the photo does not hold
  remove  names the photo holds that this plugin set last time and that are no longer desired

  Names are compared without regard to case (Lightroom's keywords are not case-sensitive, so
  renaming "alex" to "Alex" must not remove the keyword it just matched). A keyword the plugin
  did not set is never in `remove`, whatever the photo holds, so what you add by hand stays. A name
  that was set last time and is no longer on the photo (you removed it by hand) is not in `remove`
  either: there is nothing to take off.
]]
function M.peopleChanges(desired, previouslySet, current)
    local want, mine, have = lowerSet(desired), lowerSet(previouslySet), lowerSet(current)
    local add, remove, seen = {}, {}, {}
    for _, name in ipairs(desired or {}) do
        local lower = name:lower()
        if not have[lower] and not seen[lower] then
            seen[lower] = true
            add[#add + 1] = name
        end
    end
    seen = {}
    for _, name in ipairs(current or {}) do
        local lower = name:lower()
        if mine[lower] and not want[lower] and not seen[lower] then
            seen[lower] = true
            remove[#remove + 1] = name
        end
    end
    return add, remove
end

--[[
  peoplePlan(desired, stored, current) -> plan or nil

    stored   the hidden peopleSet field (a pipe-joined string, or nil)

  nil when there is nothing to do: the desired set is what the plugin set last time and the photo
  holds all of it. Otherwise { add = {...}, remove = {...}, store = string or nil }: `store` is the
  new peopleSet, the desired set, and is what the next sync compares against.
]]
function M.peoplePlan(desired, stored, current)
    local previous = M.parsePeopleSet(stored)
    local add, remove = M.peopleChanges(desired, previous, current)
    local store = M.serializePeopleSet(desired)
    if #add == 0 and #remove == 0 and store == M.serializePeopleSet(previous) then return nil end
    return { add = add, remove = remove, store = store }
end

-- Whether the names Culling Bay wants differ from the ones this plugin set last time. A cheap
-- check that reads no keywords: it is what the launch offer counts.
function M.peopleDiffers(desired, stored)
    return M.serializePeopleSet(desired) ~= M.serializePeopleSet(M.parsePeopleSet(stored))
end

-- Splits a caption into the plugin's note line (when its first line is one) and the rest.
local function splitNote(caption)
    local first, rest = caption:match('^([^\n]*)\n(.*)$')
    if not first then first, rest = caption, '' end
    first = chomp(first)
    if first:sub(1, #M.NOTE_PREFIX) == M.NOTE_PREFIX then return first, rest end
    return nil, caption
end

--[[
  mergeCaption(current, prevAI, newAI, note, firstSync) -> caption, aiToStore, status

    current   the caption in Lightroom now ('' or nil when empty)
    prevAI    the hidden aiCaption field: the AI sentence this plugin last wrote, M.YOURS, or nil
              (nil = never written by v2)
    newAI     the incoming AI sentence; nil or '' = no AI change for this photo
    note      nil = no phone decision, leave any note line as it is; '' = remove the note line;
              otherwise the note line to set
    firstSync what to do with a caption v2 has no record of writing that differs from newAI:
              'replace' (treat it as an old AI caption) or 'keep' (treat it as yours)

  status: 'unchanged' | 'written' | 'replaced' | 'adopted' | 'kept_yours' |
          'kept_edited' | 'kept_unknown'. The last two are reported in the receipt.
]]
function M.mergeCaption(current, prevAI, newAI, note, firstSync)
    current = current or ''
    local noteLine, body = splitNote(current)
    local store, status = prevAI, 'unchanged'

    if newAI and newAI ~= '' then
        if prevAI == M.YOURS then
            if body == '' then
                body, store, status = newAI, newAI, 'written'   -- you cleared it; the AI may fill it
            else
                status = 'kept_yours'
            end
        elseif prevAI and prevAI ~= '' then
            local s, e = body:find(prevAI, 1, true)
            if s then
                if prevAI ~= newAI then
                    body = body:sub(1, s - 1) .. newAI .. body:sub(e + 1)
                    status = 'replaced'
                end
                store = newAI
            else
                store, status = M.YOURS, 'kept_edited'          -- you edited the AI's sentence
            end
        elseif body == '' then
            body, store, status = newAI, newAI, 'written'
        elseif body == newAI then
            store, status = newAI, 'adopted'
        elseif firstSync == 'replace' then
            body, store, status = newAI, newAI, 'replaced'
        else
            store, status = M.YOURS, 'kept_unknown'
        end
    end

    if note ~= nil then
        noteLine = (note ~= '') and note or nil
    end
    local out = body
    if noteLine then
        out = (body ~= '') and (noteLine .. '\n' .. body) or noteLine
    end
    return out, store, status
end

--[[
  decideFlag(current, mine, target) -> action, newMine
  decideStars has the same shape, for the star rating.

    current  Lightroom's value now: pickStatus 1 / 0 / -1, or rating 0-5 (nil = 0)
    mine     the value this plugin last set (hidden field), or nil
    target   the phone's value (stars: nil = no Hero, which means 0)

  action: 'already' (nothing to write), 'set' (write target), 'kept' (a value you set by hand,
  left alone and reported). The plugin only overwrites what it set itself.
]]
local function decide(current, mine, target)
    current, target = current or 0, target or 0
    if current == target then return 'already', mine end
    if target == 0 and mine == nil then return 'already', mine end   -- nothing of ours to remove
    if current == 0 or (mine ~= nil and mine == current) then
        if target == 0 then return 'set', nil end
        return 'set', target
    end
    return 'kept', mine
end

M.decideFlag  = decide
M.decideStars = decide

function M.receiptLine(folder, fname, outcome, detail)
    return table.concat({ folder, fname, outcome, detail or '' }, '\t')
end

--[[
  catalogLine(folder, fname, pick, rating, mineFlag, mineStars): one row of the catalog file the
  plugin leaves after every sync, so Culling Bay can show what is already flagged in Lightroom.
    folder \t file \t pickStatus \t rating \t flagBy \t starsBy
  flagBy/starsBy: 'phone' when the value is the one this plugin set from a phone decision,
  'you' when it was set some other way (by hand), '' when there is none.
]]
function M.catalogLine(folder, fname, pick, rating, mineFlag, mineStars)
    pick, rating = pick or 0, rating or 0
    local flagBy = pick ~= 0 and (mineFlag == pick and 'phone' or 'you') or ''
    local starsBy = rating ~= 0 and (mineStars == rating and 'phone' or 'you') or ''
    return table.concat({ folder, fname, tostring(pick), tostring(rating), flagBy, starsBy }, '\t')
end

-- The launch offer (Startup.lua): which shoot folders the waiting rows name, and what to ask.
function M.foldersOf(byKey)
    local seen, list = {}, {}
    for key in pairs(byKey) do
        local folder = key:match('^([^/]*)/')
        if folder and folder ~= '' and not seen[folder] then
            seen[folder] = true
            list[#list + 1] = folder
        end
    end
    table.sort(list)
    return list, seen
end

-- nPeople (optional): photos with People keywords waiting (Culling Bay's people.tsv).
function M.offerText(decRows, folders, nPhotos, nPeople)
    nPeople = nPeople or 0
    local tail = '\n\nApply them now? Nothing changes unless you say so; '
    local title, info
    if decRows > 0 then
        local shoots = #folders == 1 and folders[1]
            or (#folders <= 3 and table.concat(folders, ', ') or (folders[1] .. ' to ' .. folders[#folders]))
        title = string.format('%d phone cull%s waiting from Culling Bay', decRows, decRows == 1 and ' is' or 's are')
        info = string.format('From %s (%d photo%s in this catalog).', shoots, nPhotos, nPhotos == 1 and '' or 's')
        if nPeople > 0 then
            info = info .. string.format('\n\nAlso waiting: People keywords for %d photo%s.',
                nPeople, nPeople == 1 and '' or 's')
        end
        info = info .. tail .. 'your own flags and stars are kept, as in Sync AI Cull Data. '
    else
        title = string.format('People keywords are waiting from Culling Bay for %d photo%s',
            nPeople, nPeople == 1 and '' or 's')
        info = 'The names you gave people in Culling Bay become People keywords on those photos, and a '
            .. 'name you took off a photo loses its keyword.' .. tail
            .. 'keywords you added yourself are kept, as in Sync AI Cull Data. '
    end
    info = info .. 'Not now leaves them waiting for next time. The AI\'s labels and captions wait for '
        .. 'Sync AI Cull Data.'
    return title, info
end

return M
