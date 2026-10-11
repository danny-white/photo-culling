-- Run SyncAICull.lua once on the fake SDK, for review/tests/test_round_trip.py. Run from the
-- repo root:
--   lua5.1 lightroom-plugin/tests/run_sync.lua <photos.tsv> <file to pick in the dialog>
-- photos.tsv: one photo per line, path \t pickStatus \t rating \t caption.
-- Prints each photo afterwards: file \t pickStatus \t rating \t caption (\n escaped) \t keywords.
package.path = './lightroom-plugin/AICull.lrplugin/?.lua;./lightroom-plugin/tests/?.lua;' .. package.path
local F = require 'fake_lr'

local photos = {}
for line in io.lines(arg[1]) do
    local path, pick, rating, caption = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
    photos[#photos + 1] = F.photo(path, { pickStatus = tonumber(pick), rating = tonumber(rating), caption = caption })
end
F.catalog.photos = photos
F.dialog.openPath = arg[2]
F.dialog.answers = { 'ok' }
dofile('lightroom-plugin/AICull.lrplugin/SyncAICull.lua')

for _, p in ipairs(photos) do
    local kws = {}
    for k in pairs(p.keywords) do kws[#kws + 1] = k end
    table.sort(kws)
    io.write(table.concat({ p.path:match('([^/]+)$'), tostring(p.pickStatus), tostring(p.rating or 0),
        (p.caption:gsub('\n', '\\n')), table.concat(kws, '|') }, '\t'), '\n')
end
