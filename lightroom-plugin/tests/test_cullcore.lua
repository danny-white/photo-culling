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

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
