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

-- people.tsv ----------------------------------------------------------------------------------------
-- (v2.3) People > name keywords from Culling Bay. The AI file left waiting above would come along
-- with the menu sync, so clear it first.
os.remove(inbox .. '/pending.tsv')
local function put(name, text)
    local out = io.open(inbox .. '/' .. name, 'wb'); out:write(text); out:close()
end
local function putPeople(rows)
    put('people.tsv', '#people v1\n' .. table.concat(rows, '\n') .. '\n')
end
local function lastMessage() return F.dialog.messages[#F.dialog.messages] end
local function receiptText(stampN)
    local f = assert(io.open(inbox .. '/applied/' .. string.format('20261010-12000%d', stampN) .. '-receipt.tsv'))
    local text = f:read('*a'); f:close()
    return text
end
local function names(photo)    -- the keywords a photo holds, sorted, as one string
    local t = {}
    for k in pairs(photo.keywords) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, '; ')
end

for id, field in pairs(F.declaredFields) do
    eq('hidden field ' .. id .. ' declares no dataType (Lightroom rejects the schema)', field.dataType, nil)
    eq('hidden field ' .. id .. ' has no title (it stays hidden)', field.title, nil)
end
eq('peopleSet is declared', F.declaredFields.peopleSet ~= nil, true)

-- the very first people sync: the plugin creates People (not exported) and the name under it (exported)
local PD = '/Volumes/Passport/Pictures/2026/2026-10-04/'
local P0 = F.photo(PD .. 'IMG_0000.ARW')
F.catalog.photos = { P0 }
putPeople({ '2026-10-04\tIMG_0000.ARW\tZoe' })
F.dialog.openPath = inbox .. '/people.tsv'
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
eq('people first: Zoe', names(P0), 'People > Zoe')
eq('people first: the parent is not exported', F.catalog.keywords['People'].includeOnExport, false)
eq('people first: a name is exported', F.catalog.keywords['People > Zoe'].includeOnExport, true)
eq('people first: a name sits under the parent', F.catalog.keywords['People > Zoe']:getParent(), F.catalog.keywords['People'])
eq('people first: the parent is top level', F.catalog.keywords['People']:getParent(), nil)

-- keywords you have already, made by hand: created by the fake as plain exported keywords
local P1  = F.photo(PD .. 'IMG_0001.ARW')
local P1v = F.photo(PD .. 'IMG_0001.ARW', { virtual = true })
local P2  = F.photo(PD .. 'IMG_0002.ARW', { keywords = { 'Family', 'People > Pat' } })       -- yours, by hand
local P3  = F.photo(PD .. 'IMG_0003.ARW')
local P5  = F.photo(PD .. 'IMG_0005.ARW', { keywords = { 'People > Pat' } })                 -- not in the file
local P6  = F.photo(PD .. 'IMG_0006.ARW', { keywords = { 'Alex' } })                         -- an Alex elsewhere
local P7  = F.photo(PD .. 'IMG_0007.ARW', { keywords = { 'Family > People > Alex' } })       -- under another People
local P8  = F.photo(PD .. 'IMG_0008.ARW', { keywords = { 'People > Pat' } })                 -- an empty row, never set by us
local P9  = F.photo(PD .. 'IMG_0009.ARW', { keywords = { 'People > Alex' } })                -- you already added Alex
F.catalog.photos = { P1, P1v, P2, P3, P5, P6, P7, P8, P9 }

-- run 5: the first sync of people.tsv, picked from the menu
putPeople({
    '2026-10-04\tIMG_0001.ARW\tAlex|Sam', '2026-10-04\tIMG_0002.ARW\tAlex', '2026-10-04\tIMG_0003.ARW\tSam',
    '2026-10-04\tIMG_0006.ARW\tAlex', '2026-10-04\tIMG_0007.ARW\tAlex', '2026-10-04\tIMG_0008.ARW\t',
    '2026-10-04\tIMG_0009.ARW\tAlex', '2026-10-04\tNOTREAL.ARW\tAlex' })
F.dialog.openPath = inbox .. '/people.tsv'
local writes0, reads0, stamp0 = F.writes, F.keywordReads, F.stampN or 0
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
print(lastMessage())
eq('people: Alex and Sam on P1', names(P1), 'People > Alex; People > Sam')
eq('people: P1 remembers the pair', P1.props.peopleSet, 'Alex|Sam')
eq('people: a virtual copy gets them too', names(P1v), 'People > Alex; People > Sam')
eq('people: your own keywords stay on P2', names(P2), 'Family; People > Alex; People > Pat')
eq('people: P2 remembers only Alex', P2.props.peopleSet, 'Alex')
eq('people: P3', names(P3), 'People > Sam')
eq('people: an Alex elsewhere is not People > Alex', names(P6), 'Alex; People > Alex')
eq('people: People under another parent is not People', names(P7), 'Family > People > Alex; People > Alex')
eq('people: a photo with no row is untouched', names(P5), 'People > Pat')
eq('people: an empty row that was never ours does nothing', names(P8), 'People > Pat')
eq('people: nothing remembered for it', P8.props.peopleSet, nil)
eq('people: a keyword you had added is taken as ours from here', P9.props.peopleSet, 'Alex')
eq('people: ... and not added twice', names(P9), 'People > Alex')
eq('people: a name is exported', F.catalog.keywords['People > Alex'].includeOnExport, true)
eq('people: the file stays in the inbox', exists(inbox .. '/people.tsv'), true)
eq('people: and is not filed under applied/', exists(inbox .. '/applied/20261010-12000' .. F.stampN .. '-people.tsv'), false)
eq('people: summary counts rows, photos, keywords',
    lastMessage():find('People: 8 row(s); 7 photo(s) changed, 8 keyword(s) added and 0 removed.', 1, true) ~= nil, true)
eq('people: the receipt counts them (as a comment line the server skips)',
    receiptText(F.stampN):find('#cull-receipt v1\n#people photos=7 added=8 removed=0', 1, true) == 1, true)
eq('people: keywords read only for photos with names or something of ours', F.keywordReads - reads0, 7)

-- run 6: the same file again changes nothing at all
writes0, reads0 = F.writes, F.keywordReads
local msgs = #F.dialog.messages
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
eq('people again: no catalog change', F.writes - writes0, 0)
eq('people again: the keywords are checked, not rewritten', F.keywordReads - reads0, 7)
eq('people again: counted as nothing',
    lastMessage():find('People: 8 row(s); 0 photo(s) changed, 0 keyword(s) added and 0 removed.', 1, true) ~= nil, true)

-- run 7: Culling Bay took Sam off P1 and Alex off P2 and P9, and added Alex to P3. You added Zed to P1
-- and Pat to P3 yourself.
local function addByHand(photo, full)
    local kw = F.photo('x', { keywords = { full } }).kwObjs[full]
    photo.keywords[full], photo.kwObjs[full] = true, kw
end
addByHand(P1, 'People > Zed'); addByHand(P3, 'People > Pat')
putPeople({
    '2026-10-04\tIMG_0001.ARW\tAlex', '2026-10-04\tIMG_0002.ARW\t', '2026-10-04\tIMG_0003.ARW\tAlex|Sam',
    '2026-10-04\tIMG_0006.ARW\tAlex', '2026-10-04\tIMG_0007.ARW\tAlex', '2026-10-04\tIMG_0008.ARW\t',
    '2026-10-04\tIMG_0009.ARW\t' })
writes0, reads0 = F.writes, F.keywordReads
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
print(lastMessage())
eq('people 2: Sam off P1, your Zed stays', names(P1), 'People > Alex; People > Zed')
eq('people 2: P1 remembers Alex only', P1.props.peopleSet, 'Alex')
eq('people 2: and the virtual copy follows', names(P1v), 'People > Alex')
eq('people 2: Alex off P2, your Family and Pat stay', names(P2), 'Family; People > Pat')
eq('people 2: P2 remembers nobody', P2.props.peopleSet, nil)
eq('people 2: Alex added to P3, your Pat stays', names(P3), 'People > Alex; People > Pat; People > Sam')
eq('people 2: P3 remembers both', P3.props.peopleSet, 'Alex|Sam')
eq('people 2: the Alex you had added is ours once Culling Bay has said so, and goes', names(P9), '')
eq('people 2: P5, P6, P7, P8 as they were', names(P5) .. '|' .. names(P6) .. '|' .. names(P7) .. '|' .. names(P8),
    'People > Pat|Alex; People > Alex|Family > People > Alex; People > Alex|People > Pat')
eq('people 2: summary',
    lastMessage():find('People: 7 row(s); 5 photo(s) changed, 1 keyword(s) added and 4 removed.', 1, true) ~= nil, true)
eq('people 2: the empty rows read nothing but P9 (which was ours)', F.keywordReads - reads0, 7)

-- run 8: you take a wanted keyword off by hand: it comes back. You also remove one we set: nothing to remove.
P3.keywords['People > Alex'], P3.kwObjs['People > Alex'] = nil, nil
writes0 = F.writes
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
eq('people 3: the wanted keyword is put back', names(P3), 'People > Alex; People > Pat; People > Sam')
eq('people 3: nothing else changed', lastMessage():find('1 photo(s) changed, 1 keyword(s) added and 0 removed.', 1, true) ~= nil, true)

-- the launch offer for people: the shoots are found without a selection, and only photos whose names
-- differ from what we set are counted; people.tsv stays, so it must not be offered twice
local Q1 = F.photo('/Volumes/Passport/Pictures/2026/2026-10-05/IMG_1001.ARW')
local Q2 = F.photo('/Volumes/Passport/Pictures/2026/2026-10-05/IMG_1002.ARW')
local Q3 = F.photo('/Volumes/Passport/Pictures/2026/2026-10-06/IMG_1003.ARW')
F.catalog.folders = { F.folder('Pictures', { F.folder('2026', {
    F.folder('2026-10-05', {}, { Q1, Q2 }), F.folder('2026-10-06', {}, { Q3 }) }) }) }
F.catalog.photos = { P1 }                    -- the selection plays no part
putPeople({ '2026-10-05\tIMG_1001.ARW\tAlex', '2026-10-05\tIMG_1002.ARW\tSam', '2026-10-06\tIMG_1003.ARW\t',
            '2026-11-01\tNOTHERE.ARW\tAlex' })       -- the last shoot is not in this catalog
nConfirms, nMsgs = #F.dialog.confirms, #F.dialog.messages
F.dialog.answers = { 'cancel' }
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch people: asked once', #F.dialog.confirms, nConfirms + 1)
eq('launch people: counts the two photos that would change',
    F.dialog.confirms[#F.dialog.confirms], 'People keywords are waiting from Culling Bay for 2 photos')
eq('launch people: Not now applies nothing', names(Q1) .. names(Q2), '')
eq('launch people: Not now leaves the file', exists(inbox .. '/people.tsv'), true)
F.dialog.answers = { 'ok' }
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch people: Apply adds Alex', names(Q1), 'People > Alex')
eq('launch people: Apply adds Sam', names(Q2), 'People > Sam')
eq('launch people: an empty row never set by us does nothing', names(Q3), '')
eq('launch people: the file stays in the inbox', exists(inbox .. '/people.tsv'), true)
eq('launch people: the selection is not touched', names(P1), 'People > Alex; People > Zed')
nConfirms = #F.dialog.confirms
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch people: nothing differs now, so nothing is asked', #F.dialog.confirms, nConfirms)

-- a phone cull and a people change at once: one question, one pass
putPeople({ '2026-10-05\tIMG_1001.ARW\tAlex|Sam', '2026-10-05\tIMG_1002.ARW\tSam', '2026-10-06\tIMG_1003.ARW\t' })
put('cull-decisions.tsv', '#cull-decisions v1\n2026-10-06\tIMG_1003.ARW\treject\t\t\n')
F.dialog.answers = { 'ok' }
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
local title = F.dialog.confirms[#F.dialog.confirms]
eq('launch both: the culls head the question', title, '1 phone cull is waiting from Culling Bay')
eq('launch both: Q3 rejected', Q3.pickStatus, -1)
eq('launch both: Q1 gets Sam too', names(Q1), 'People > Alex; People > Sam')
eq('launch both: the phone file is filed under applied/', exists(inbox .. '/cull-decisions.tsv'), false)
eq('launch both: the people file is not', exists(inbox .. '/people.tsv'), true)
eq('launch both: the summary has both',
    lastMessage():find('1 flag(s) set', 1, true) ~= nil and lastMessage():find('1 photo(s) changed, 1 keyword(s) added', 1, true) ~= nil, true)

-- only shoots this catalog doesn't have: silent
putPeople({ '2026-11-01\tNOTHERE.ARW\tAlex' })
nConfirms = #F.dialog.confirms
dofile('lightroom-plugin/AICull.lrplugin/Startup.lua')
eq('launch people: shoots not in the catalog are not offered', #F.dialog.confirms, nConfirms)

-- the menu sync takes the phone file along with people.tsv and files only that one
putPeople({ '2026-10-05\tIMG_1002.ARW\tSam|Alex' })
put('cull-decisions.tsv', '#cull-decisions v1\n2026-10-05\tIMG_1002.ARW\tpick\t3\t\n')
F.catalog.photos = { Q1, Q2, Q3 }
F.dialog.openPath = inbox .. '/people.tsv'
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')
eq('menu: people from the picked file', names(Q2), 'People > Alex; People > Sam')
eq('menu: the phone file came along', Q2.pickStatus .. ' ' .. tostring(Q2.rating), '1 3')
eq('menu: the phone file was filed', exists(inbox .. '/cull-decisions.tsv'), false)
eq('menu: people.tsv was not', exists(inbox .. '/people.tsv'), true)
eq('menu: one receipt holds both',
    receiptText(F.stampN):find('#people photos=1 added=1 removed=0\n', 1, true) ~= nil
        and receiptText(F.stampN):find('IMG_1002.ARW\tapplied\tpick', 1, true) ~= nil, true)

os.execute('rm -rf "' .. inbox .. '"')
print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
