-- Unit tests for CullCore.lua (the plugin's pure logic). Lightroom runs Lua 5.1, so run with:
--   lua5.1 lightroom-plugin/tests/test_cullcore.lua
package.path = './lightroom-plugin/AICull.lrplugin/?.lua;../AICull.lrplugin/?.lua;' .. package.path
local C = require 'CullCore'

local passed, failed = 0, 0
local function eq(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format('FAIL %s\n  got:  %q\n  want: %q', name, tostring(got), tostring(want)))
    end
end
local NOTE = C.NOTE_PREFIX .. 'DSC05015'

-- parsing ---------------------------------------------------------------------------------
do
    local key, r = C.parseAILine('2026-10-01\tDSC05012.ARW\tYellow\tCull-review|Stars-3\tA caption.\r')
    eq('ai key', key, '2026-10-01/DSC05012.ARW')
    eq('ai label', r.label, 'Yellow')
    eq('ai keywords', #r.keywords, 2)
    eq('ai caption, CRLF stripped', r.caption, 'A caption.')
    eq('ai header skipped', C.parseAILine('#cull-decisions v1'), nil)
    eq('ai blank skipped', C.parseAILine(''), nil)
    local _, r2 = C.parseAILine('f\tx.ARW\t\t\t')
    eq('ai empty caption', r2.caption, '')
end
do
    local key, d = C.parseDecisionLine('2026-10-01\tDSC05013.ARW\treject\t\t' .. NOTE)
    eq('dec key', key, '2026-10-01/DSC05013.ARW')
    eq('dec reject', d.pick, -1)
    eq('dec no stars', d.stars, nil)
    eq('dec note', d.note, NOTE)
    local _, h = C.parseDecisionLine('f\tx.ARW\tpick\t5\t')
    eq('dec hero stars', h.stars, 5)
    eq('dec hero pick', h.pick, 1)
    eq('dec empty note', h.note, '')
    local _, n = C.parseDecisionLine('f\tx.ARW\tnone\t\t')
    eq('dec none', n.pick, 0)
    eq('dec bad flag', C.parseDecisionLine('f\tx.ARW\tmaybe\t\t'), nil)
    eq('dec header', C.isDecisionsHeader('#cull-decisions v1\r'), true)
    eq('dec not header', C.isDecisionsHeader('2026-10-01\tx'), false)
end

-- caption: the table in the design doc ------------------------------------------------------
local function merge(...) local c, s, st = C.mergeCaption(...); return c, s, st end
do
    local c, s, st = merge('', nil, 'AI one.', nil, 'keep')
    eq('empty -> written', c, 'AI one.'); eq('empty store', s, 'AI one.'); eq('empty status', st, 'written')

    c, s, st = merge('AI one.', 'AI one.', 'AI one, revised.', nil, 'keep')
    eq('own sentence replaced', c, 'AI one, revised.'); eq('own store', s, 'AI one, revised.'); eq('own status', st, 'replaced')

    c, s, st = merge('AI one. My words.', 'AI one.', 'AI two.', nil, 'keep')
    eq('your text stays', c, 'AI two. My words.'); eq('your text status', st, 'replaced')

    c, s, st = merge('AI one, fixed by me.', 'AI one.', 'AI two.', nil, 'keep')
    eq('edited -> left', c, 'AI one, fixed by me.'); eq('edited store', s, C.YOURS); eq('edited status', st, 'kept_edited')

    c, s, st = merge('AI one.', nil, 'AI one.', nil, 'keep')
    eq('first sync equal -> adopted', st, 'adopted'); eq('adopted store', s, 'AI one.'); eq('adopted caption', c, 'AI one.')

    c, s, st = merge('Old AI text.', nil, 'AI new.', nil, 'keep')
    eq('first sync differs, keep', c, 'Old AI text.'); eq('keep store', s, C.YOURS); eq('keep status', st, 'kept_unknown')

    c, s, st = merge('Old AI text.', nil, 'AI new.', nil, 'replace')
    eq('first sync differs, replace', c, 'AI new.'); eq('replace store', s, 'AI new.'); eq('replace status', st, 'replaced')

    c, s, st = merge('Mine.', C.YOURS, 'AI new.', nil, 'keep')
    eq('yours stays quiet', c, 'Mine.'); eq('yours status', st, 'kept_yours'); eq('yours store', s, C.YOURS)

    c, s, st = merge('', C.YOURS, 'AI new.', nil, 'keep')
    eq('yours cleared -> AI fills', c, 'AI new.'); eq('yours cleared store', s, 'AI new.')

    c, s, st = merge('AI one.', 'AI one.', 'AI one.', nil, 'keep')
    eq('no change', st, 'unchanged'); eq('no change caption', c, 'AI one.')

    c, s, st = merge('AI one.', 'AI one.', nil, nil, 'keep')
    eq('no AI row leaves caption', c, 'AI one.'); eq('no AI row store', s, 'AI one.')
end

-- caption: the burst note line -------------------------------------------------------------
do
    local c = merge('AI one.', 'AI one.', nil, NOTE, 'keep')
    eq('note added above', c, NOTE .. '\nAI one.')

    c = merge('', nil, 'AI one.', NOTE, 'keep')
    eq('note + AI on empty', c, NOTE .. '\nAI one.')

    c = merge('', nil, nil, NOTE, 'keep')
    eq('note alone', c, NOTE)

    c = merge(NOTE .. '\nAI one.', 'AI one.', nil, C.NOTE_PREFIX .. 'DSC05016', 'keep')
    eq('note replaced', c, C.NOTE_PREFIX .. 'DSC05016\nAI one.')

    c = merge(NOTE .. '\nAI one.', 'AI one.', nil, '', 'keep')
    eq('note removed (rescued)', c, 'AI one.')

    c = merge(NOTE .. '\nAI one.', 'AI one.', 'AI two.', nil, 'keep')
    eq('AI updated under the note', c, NOTE .. '\nAI two.')

    c = merge(NOTE, nil, 'AI one.', nil, 'keep')
    eq('AI written under an existing note', c, NOTE .. '\nAI one.')

    c = merge('Burst of joy\nAI one.', 'AI one.', nil, NOTE, 'keep')
    eq('a line that only looks similar is not the note', c, NOTE .. '\nBurst of joy\nAI one.')

    c = merge(NOTE .. '\r\nAI one.', 'AI one.', nil, '', 'keep')
    eq('CRLF after the note', c, 'AI one.')
end

-- flags and stars --------------------------------------------------------------------------
do
    local a, m = C.decideFlag(0, nil, -1)
    eq('unflagged -> set', a, 'set'); eq('unflagged mine', m, -1)
    a, m = C.decideFlag(1, nil, -1)
    eq('your pick kept', a, 'kept'); eq('your pick mine', m, nil)
    a, m = C.decideFlag(-1, -1, 1)
    eq('own reject -> rescued', a, 'set'); eq('rescued mine', m, 1)
    a, m = C.decideFlag(1, -1, -1)
    eq('you changed ours by hand -> kept', a, 'kept')
    a, m = C.decideFlag(-1, nil, -1)
    eq('same flag already', a, 'already'); eq('already does not claim it', m, nil)
    a, m = C.decideFlag(1, nil, 0)
    eq('none never clears your flag', a, 'already')
    a, m = C.decideFlag(-1, -1, 0)
    eq('none clears our flag', a, 'set'); eq('cleared mine', m, nil)
    a = C.decideFlag(nil, nil, 1)
    eq('nil pickStatus counts as unflagged', a, 'set')

    a, m = C.decideStars(0, nil, 5)
    eq('hero on unrated', a, 'set'); eq('hero mine', m, 5)
    a = C.decideStars(2, nil, 5)
    eq('your stars kept', a, 'kept')
    a = C.decideStars(3, nil, nil)
    eq('no hero leaves your stars', a, 'already')
    a, m = C.decideStars(5, 5, nil)
    eq('hero undone clears ours', a, 'set'); eq('hero undone mine', m, nil)
end

eq('receipt line', C.receiptLine('f', 'x.ARW', 'applied'), 'f\tx.ARW\tapplied\t')
eq('catalog: your pick', C.catalogLine('f', 'x.ARW', 1, nil, nil, nil), 'f\tx.ARW\t1\t0\tyou\t')
eq('catalog: phone reject', C.catalogLine('f', 'x.ARW', -1, 0, -1, nil), 'f\tx.ARW\t-1\t0\tphone\t')
eq('catalog: you changed a phone flag', C.catalogLine('f', 'x.ARW', 1, 0, -1, nil), 'f\tx.ARW\t1\t0\tyou\t')
eq('catalog: phone hero', C.catalogLine('f', 'x.ARW', 1, 5, 1, 5), 'f\tx.ARW\t1\t5\tphone\tphone')
eq('catalog: unflagged, your stars', C.catalogLine('f', 'x.ARW', 0, 3, nil, nil), 'f\tx.ARW\t0\t3\t\tyou')

-- the launch offer
do
    local byKey = { ['2026-10-01/A.ARW'] = {}, ['2026-09-29/B.ARW'] = {}, ['2026-10-01/C.ARW'] = {}, ['/x'] = {} }
    local folders, set = C.foldersOf(byKey)
    eq('folders: distinct, sorted', table.concat(folders, ','), '2026-09-29,2026-10-01')
    eq('folders: as a set', set['2026-10-01'], true)
    local title, info = C.offerText(26, folders, 32)
    eq('offer title', title, '26 phone culls are waiting from Culling Bay')
    eq('offer names the shoots', info:sub(1, 49), 'From 2026-09-29, 2026-10-01 (32 photos in this ca')
    title, info = C.offerText(1, { 'a', 'b', 'c', 'd' }, 1)
    eq('offer title, one', title, '1 phone cull is waiting from Culling Bay')
    eq('offer, many shoots', info:sub(1, 30), 'From a to d (1 photo in this c')
    eq('offer: no people, no mention', select(2, C.offerText(26, folders, 32, 0)):find('People', 1, true), nil)
    title, info = C.offerText(26, folders, 32, 5)
    eq('offer with people: same title', title, '26 phone culls are waiting from Culling Bay')
    eq('offer with people: says so', info:find('Also waiting: People keywords for 5 photos.', 1, true) ~= nil, true)
    title, info = C.offerText(0, {}, 0, 1)
    eq('offer, people only', title, 'People keywords are waiting from Culling Bay for 1 photo')
    eq('offer, people only: keeps your own', info:find('keywords you added yourself are kept', 1, true) ~= nil, true)
    eq('offer, people only: asks first', info:find('Nothing changes unless you say so', 1, true) ~= nil, true)
end

-- people.tsv: the rows ------------------------------------------------------------------------
do
    local key, r = C.parsePeopleLine('2026-10-01\tDSC05012.ARW\tAlex|Sam\r')
    eq('people key', key, '2026-10-01/DSC05012.ARW')
    eq('people folder', r.folder, '2026-10-01')
    eq('people file', r.fname, 'DSC05012.ARW')
    eq('people names', table.concat(r.names, ','), 'Alex,Sam')
    local _, empty = C.parsePeopleLine('2026-10-01\tDSC05013.ARW\t')
    eq('people: a row with no names is kept', #empty.names, 0)
    local k2, bare = C.parsePeopleLine('2026-10-01\tDSC05013.ARW')
    eq('people: a row with no third column is kept too', k2, '2026-10-01/DSC05013.ARW')
    eq('people: ... as no names', #bare.names, 0)
    local _, spaced = C.parsePeopleLine('f\tx.ARW\t Alex | sam ||alex|')
    eq('people: trimmed, no empties, one of each case aside', table.concat(spaced.names, ','), 'Alex,sam')
    local _, extra = C.parsePeopleLine('f\tx.ARW\tAlex\tsomething else')
    eq('people: only the third column is names', table.concat(extra.names, ','), 'Alex')
    eq('people header skipped', C.parsePeopleLine('#people v1'), nil)
    eq('people blank skipped', C.parsePeopleLine(''), nil)
    eq('people: no file name', C.parsePeopleLine('f\t\tAlex'), nil)
    eq('people: not a row', C.parsePeopleLine('just words'), nil)
    eq('people header', C.isPeopleHeader('#people v1\r'), true)
    eq('people: the decisions header is not it', C.isPeopleHeader('#cull-decisions v1'), false)
    eq('people: a nil first line (empty file)', C.isPeopleHeader(nil), false)
    eq('people: the other parsers skip the header', C.parseAILine('#people v1') == nil
        and C.parseDecisionLine('#people v1') == nil, true)
end

-- people.tsv: the set stored in the hidden field ------------------------------------------------
do
    eq('set: alphabetical, case aside', C.serializePeopleSet({ 'sam', 'Alex', 'Zoe' }), 'Alex|sam|Zoe')
    eq('set: the same set gives the same string', C.serializePeopleSet({ 'Sam', 'Alex' }), C.serializePeopleSet({ 'Alex', 'Sam' }))
    eq('set: a name once', C.serializePeopleSet({ 'Alex', 'alex' }), 'Alex')
    eq('set: empty clears the field', C.serializePeopleSet({}), nil)
    eq('set: nil too', C.serializePeopleSet(nil), nil)
    eq('set: read back', table.concat(C.parsePeopleSet('Alex|Sam'), ','), 'Alex,Sam')
    eq('set: nothing stored', #C.parsePeopleSet(nil), 0)
    eq('set: an empty string', #C.parsePeopleSet(''), 0)
    eq('differs: same names', C.peopleDiffers({ 'Sam', 'Alex' }, 'Alex|Sam'), false)
    eq('differs: a new name', C.peopleDiffers({ 'Alex', 'Sam' }, 'Alex'), true)
    eq('differs: nothing wanted, nothing set', C.peopleDiffers({}, nil), false)
    eq('differs: nothing wanted, something set', C.peopleDiffers({}, 'Alex'), true)
    eq('differs: something wanted, nothing set', C.peopleDiffers({ 'Alex' }, nil), true)
end

-- people.tsv: what to add and remove -------------------------------------------------------------
do
    local function names(t) return table.concat(t, ',') end
    local add, remove = C.peopleChanges({ 'Alex', 'Sam' }, {}, {})
    eq('first sync: add both', names(add), 'Alex,Sam'); eq('first sync: remove none', names(remove), '')

    add, remove = C.peopleChanges({ 'Alex', 'Sam' }, { 'Alex' }, { 'Alex' })
    eq('a new name is added', names(add), 'Sam'); eq('nothing removed', names(remove), '')

    add, remove = C.peopleChanges({ 'Alex' }, { 'Alex' }, { 'Alex' })
    eq('already there: nothing to add', names(add), ''); eq('still wanted: nothing to remove', names(remove), '')

    add, remove = C.peopleChanges({ 'Alex' }, {}, { 'Alex' })
    eq('you added it by hand: not added again', names(add), ''); eq('... and not removed', names(remove), '')

    add, remove = C.peopleChanges({}, { 'Alex', 'Sam' }, { 'Alex', 'Sam' })
    eq('no longer in the photo: add none', names(add), ''); eq('no longer in the photo: remove what we set', names(remove), 'Alex,Sam')

    add, remove = C.peopleChanges({}, { 'Alex' }, { 'Alex', 'Pat' })
    eq('a keyword we did not set survives', names(remove), 'Alex')

    add, remove = C.peopleChanges({}, {}, { 'Pat' })
    eq('never set by us: never removed', names(remove), '')

    add, remove = C.peopleChanges({}, { 'Alex' }, {})
    eq('we set it, you removed it: nothing left to remove', names(remove), '')

    add, remove = C.peopleChanges({ 'Alex' }, { 'Alex' }, {})
    eq('you removed a wanted keyword: it comes back', names(add), 'Alex')

    add, remove = C.peopleChanges({ 'alex' }, { 'Alex' }, { 'Alex' })
    eq('renamed in case only: not added', names(add), ''); eq('... and the keyword is not removed', names(remove), '')

    add, remove = C.peopleChanges({ 'Alexander' }, { 'Alex' }, { 'Alex' })
    eq('renamed: the new name added', names(add), 'Alexander'); eq('renamed: the old name removed', names(remove), 'Alex')

    add, remove = C.peopleChanges({ 'Alex', 'ALEX' }, {}, {})
    eq('a name once', names(add), 'Alex')

    add, remove = C.peopleChanges(nil, nil, nil)
    eq('nothing at all', #add + #remove, 0)
end

do
    eq('plan: nothing to do', C.peoplePlan({ 'Alex' }, 'Alex', { 'Alex' }), nil)
    eq('plan: nothing wanted, nothing set', C.peoplePlan({}, nil, {}), nil)
    eq('plan: a name that is not ours stays out of it', C.peoplePlan({}, nil, { 'Pat' }), nil)
    local p = C.peoplePlan({ 'Alex', 'Sam' }, nil, {})
    eq('plan: add', table.concat(p.add, ','), 'Alex,Sam'); eq('plan: store', p.store, 'Alex|Sam')
    p = C.peoplePlan({ 'Alex' }, 'Alex', {})
    eq('plan: the keyword is gone, put it back', table.concat(p.add, ','), 'Alex'); eq('plan: store unchanged', p.store, 'Alex')
    p = C.peoplePlan({}, 'Alex', { 'Alex', 'Pat' })
    eq('plan: remove ours', table.concat(p.remove, ','), 'Alex'); eq('plan: field cleared', p.store, nil)
    p = C.peoplePlan({ 'Alex' }, nil, { 'Alex' })
    eq('plan: held by hand, now wanted: nothing to add', #p.add, 0)
    eq('plan: ... remembered, so a later removal is ours', p.store, 'Alex')
    p = C.peoplePlan({}, 'Alex', {})
    eq('plan: set by us, gone by hand, no longer wanted: just forget it', #p.add + #p.remove, 0)
    eq('plan: ... forgotten', p.store, nil)
end

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
