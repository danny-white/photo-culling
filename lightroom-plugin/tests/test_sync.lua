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
eq('no colour label, though the file has one', A.label, '')
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
local cat, catRows = {}, 0
for line in io.lines(inbox .. '/applied/20261010-120001-catalog.tsv') do
    if line:sub(1, 1) ~= '#' then
        catRows = catRows + 1
        local _, fname, rest = line:match('^([^\t]*)\t([^\t]*)\t(.*)$')
        cat[fname] = rest
    end
end
eq('catalog: one row per photo, virtual copy left out', catRows, 7)
eq('catalog: your own pick', cat['DSC05038.ARW'], '1\t0\tyou\t')
eq('catalog: a phone reject', cat['DSC05036.ARW'], '-1\t0\tphone\t')
eq('catalog: phone hero', cat['DSC05037.ARW'], '1\t5\tphone\tphone')
eq('catalog: phone pick, your stars', cat['DSC05040.ARW'], '1\t2\tphone\tyou')
eq('catalog: untouched', cat['DSC05041.ARW'], '0\t0\t\t')

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

-- run 3: the phone file alone (the AI's pending.tsv already synced) must still be applied and moved
local only = io.open(inbox .. '/cull-decisions.tsv', 'wb')
only:write('#cull-decisions v1\n2026-10-01\tDSC05041.ARW\treject\t\t\n'); only:close()
F.dialog.openPath = inbox .. '/cull-decisions.tsv'
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
eq('decisions-only run applied', Fp.pickStatus, -1)
eq('decisions-only run moved its input', exists(inbox .. '/cull-decisions.tsv'), false)
eq('decisions-only input kept in applied/', exists(inbox .. '/applied/20261010-120003-cull-decisions.tsv'), true)

-- run 4: the launch offer (Startup.lua). Two shoots' rows wait; the catalog finds them by folder,
-- without a selection. "Not now" leaves everything waiting; "Apply" runs the sync on them.
local Sync = require 'Sync'
Sync.INBOX = inbox
local O1 = F.photo('/Volumes/Passport/Pictures/2026/2026-10-02/DSC06001.ARW')
local O2 = F.photo('/Volumes/Passport/Pictures/2026/2026-10-03/DSC06101.ARW')
local Other = F.photo('/Volumes/Passport/Pictures/2025/2025-10-02/DSC06001.ARW')   -- same file name, another shoot
F.catalog.folders = { F.folder('Pictures', {
    F.folder('2025', { F.folder('2025-10-02', {}, { Other }) }),
    F.folder('2026', { F.folder('2026-10-01', {}, { A, B }), F.folder('2026-10-02', {}, { O1 }), F.folder('2026-10-03', {}, { O2 }) }) }) }
F.catalog.photos = { A }                     -- the selection plays no part
local waiting = io.open(inbox .. '/cull-decisions.tsv', 'wb')
waiting:write('#cull-decisions v1\n2026-10-02\tDSC06001.ARW\treject\t\t\n2026-10-03\tDSC06101.ARW\tpick\t3\t\n'); waiting:close()
local ai = io.open(inbox .. '/pending.tsv', 'wb')       -- the AI's file waits for the menu sync
ai:write('2026-10-02\tDSC06001.ARW\tRed\tTEST-AI\tTEST AI: launch.\n'); ai:close()
local nConfirms = #F.dialog.confirms
F.dialog.answers = { 'cancel' }
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch: asked once', #F.dialog.confirms, nConfirms + 1)
eq('launch: names the culls', F.dialog.confirms[#F.dialog.confirms], '2 phone culls are waiting from Culling Bay')
eq('launch: Not now applies nothing', O1.pickStatus .. ' ' .. O2.pickStatus, '0 0')
eq('launch: Not now leaves the file waiting', exists(inbox .. '/cull-decisions.tsv'), true)
F.dialog.answers = { 'ok' }
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch: Apply rejects O1', O1.pickStatus, -1)
eq('launch: Apply picks O2 with stars', O2.pickStatus .. ' ' .. tostring(O2.rating), '1 3')
eq('launch: same file name in another shoot untouched', Other.pickStatus, 0)
eq('launch: the selection untouched', A.pickStatus, 1)
eq('launch: input moved to applied/', exists(inbox .. '/cull-decisions.tsv'), false)
eq('launch: the AI file left waiting', exists(inbox .. '/pending.tsv'), true)
eq('launch: no AI caption applied', O1.caption, '')
local nMsgs = #F.dialog.messages
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch: nothing waiting, nothing asked', #F.dialog.confirms, nConfirms + 2)
eq('launch: and nothing said', #F.dialog.messages, nMsgs)

os.execute('rm -rf "' .. inbox .. '"')
print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
