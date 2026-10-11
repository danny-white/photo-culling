-- End-to-end test of SyncAICull.lua against the fake SDK (fake_lr.lua), using the same two-run
-- kit as the scratch-catalog checklist (tests/kit, TESTING.md). Run from the repo root:
--   lua5.1 lightroom-plugin/tests/test_sync.lua
package.path = './lightroom-plugin/AICull.lrplugin/?.lua;./lightroom-plugin/tests/?.lua;' .. package.path
local F = require 'fake_lr'
local Core = require 'CullCore'

local passed, failed = 0, 0
local function eq(name, got, want)
    if got == want then passed = passed + 1
    else failed = failed + 1; print(string.format('FAIL %s\n  got:  %q\n  want: %q', name, tostring(got), tostring(want))) end
end

local inbox = os.tmpname(); os.remove(inbox); os.execute('mkdir -p "' .. inbox .. '"')
local function copyRun(run)
    for _, name in ipairs({ 'pending.tsv', 'cull-decisions.tsv' }) do
        local src = io.open('lightroom-plugin/tests/kit/' .. run .. '/' .. name, 'rb')
        local out = io.open(inbox .. '/' .. name, 'wb'); out:write(src:read('*a')); src:close(); out:close()
    end
end
local function exists(p) local f = io.open(p); if f then f:close(); return true end; return false end
local function receipt(stampN)
    local t = {}
    for line in io.lines(inbox .. '/applied/20261010-12000' .. stampN .. '-receipt.tsv') do
        local _, fname, outcome = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)')
        if fname then t[fname .. ' ' .. outcome] = true end
    end
    return t
end

local DIR = '/Volumes/Passport/Pictures/2026/2026-10-01/'
local A = F.photo(DIR .. 'DSC05036.ARW')
local B = F.photo(DIR .. 'DSC05037.ARW')
local C = F.photo(DIR .. 'DSC05038.ARW', { pickStatus = 1 })            -- you picked it by hand
local D = F.photo(DIR .. 'DSC05039.ARW', { caption = 'My own caption.' }) -- you typed a caption
local E = F.photo(DIR .. 'DSC05040.ARW', { rating = 2 })                  -- you gave it 2 stars
local Fp = F.photo(DIR .. 'DSC05041.ARW')
local I = F.photo(DIR .. 'DSC05042.ARW')
local Bv = F.photo(DIR .. 'DSC05037.ARW', { virtual = true })             -- a virtual copy of B
F.catalog.photos = { A, B, C, D, E, Fp, I, Bv }
local NOTE = Core.NOTE_PREFIX .. 'DSC05037'

-- run 1: pick pending.tsv; Keep at the first-sync caption question
copyRun('run1')
F.dialog.openPath = inbox .. '/pending.tsv'
F.dialog.answers = { 'ok' }
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
print(F.dialog.messages[#F.dialog.messages])

eq('one caption question', #F.dialog.confirms, 1)
eq('question counts D only', F.dialog.confirms[1], "1 caption(s) differ from the AI's new text")
eq('A rejected', A.pickStatus, -1)
eq('A caption: note over AI', A.caption, NOTE .. '\nTEST AI: A one.')
eq('A burst keyword', A.keywords['Cull > Burst reject'], true)
eq('A AI keyword', A.keywords['TEST-AI'], true)
eq('B picked', B.pickStatus, 1)
eq('B hero stars', B.rating, 5)
eq('B virtual copy flag untouched', Bv.pickStatus, 0)
eq('B virtual copy gets AI caption', Bv.caption, 'TEST AI: B one.')
eq('C your pick kept', C.pickStatus, 1)
eq('C no note when your flag wins', C.caption, 'TEST AI: C one.')
eq('C no burst keyword', C.keywords['Cull > Burst reject'], nil)
eq('D your caption kept', D.caption, 'My own caption.')
eq('D marked yours', D.props.aiCaption, Core.YOURS)
eq('E picked', E.pickStatus, 1)
eq('E your stars kept', E.rating, 2)
eq('F AI caption', Fp.caption, 'TEST AI: F one.')
eq('I AI caption', I.caption, 'TEST AI: I one.')
eq('smart collection made', F.catalog.collections['Burst rejects, similar kept'] ~= nil, true)
local r1 = receipt(1)
eq('receipt: A applied', r1['DSC05036.ARW applied'], true)
eq('receipt: C your flag kept', r1['DSC05038.ARW your_flag_kept'], true)
eq('receipt: D caption left', r1['DSC05039.ARW caption_left'], true)
eq('receipt: E your stars kept', r1['DSC05040.ARW your_stars_kept'], true)
eq('receipt: NOTREAL missing', r1['NOTREAL.ARW missing'], true)
eq('inputs moved out of the inbox', exists(inbox .. '/pending.tsv') or exists(inbox .. '/cull-decisions.tsv'), false)
eq('pending.tsv kept in applied/', exists(inbox .. '/applied/20261010-120001-pending.tsv'), true)
eq('decisions kept in applied/', exists(inbox .. '/applied/20261010-120001-cull-decisions.tsv'), true)

-- your edits between the runs, then run 2: pick cull-decisions.tsv this time
Fp.caption = Fp.caption .. ' Extra words.'
I.caption = 'TEST AI: I one, fixed by me.'
copyRun('run2')
F.dialog.openPath = inbox .. '/cull-decisions.tsv'
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
print(F.dialog.messages[#F.dialog.messages])

eq('no second caption question', #F.dialog.confirms, 1)
eq('A rescued to pick', A.pickStatus, 1)
eq('A note removed', A.caption, 'TEST AI: A one.')
eq('A burst keyword removed', A.keywords['Cull > Burst reject'], nil)
eq('B unchanged', B.pickStatus == 1 and B.rating == 5, true)
eq('C still yours', C.pickStatus, 1)
eq('D still yours, quietly', D.caption, 'My own caption.')
eq('F AI updated, your words kept', Fp.caption, 'TEST AI: F two. Extra words.')
eq('I edited sentence left alone', I.caption, 'TEST AI: I one, fixed by me.')
local r2 = receipt(2)
eq('receipt 2: I caption left', r2['DSC05042.ARW caption_left'], true)
eq('receipt 2: D not reported again', r2['DSC05039.ARW caption_left'], nil)
eq('receipt 2: C kept again', r2['DSC05038.ARW your_flag_kept'], true)

os.execute('rm -rf "' .. inbox .. '"')
print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
