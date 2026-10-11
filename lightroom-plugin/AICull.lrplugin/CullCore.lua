--[[
  Pure logic for AI Cull Sync: parsing the two inbox files, merging Caption, and deciding whether
  a flag or star rating may be written. No Lightroom imports, so it also runs under plain Lua 5.1
  for the tests in lightroom-plugin/tests/test_cullcore.lua.
]]

local M = {}

M.AI_FILE          = 'pending.tsv'
M.DECISIONS_FILE   = 'cull-decisions.tsv'
M.DECISIONS_HEADER = '#cull-decisions v1'
M.RECEIPT_HEADER   = '#cull-receipt v1'
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

return M
