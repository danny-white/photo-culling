-- Run SyncAICull.lua once on the fake SDK, for review/tests/test_round_trip.py. Run from the
-- repo root:
--   lua5.1 lightroom-plugin/tests/run_sync.lua <photos.tsv> <file to pick in the dialog>
-- photos.tsv: one photo per line, path \t pickStatus \t rating \t caption, then optionally
-- \t keywords already on the photo (full names, pipe-joined: "Family|People > Pat")
-- \t the hidden peopleSet field ("Alex|Sam").
-- Prints each photo afterwards: file \t pickStatus \t rating \t caption (\n escaped) \t keywords
-- \t peopleSet, the keywords as full names, pipe-joined and sorted.
package.path = './lightroom-plugin/AICull.lrplugin/?.lua;./lightroom-plugin/tests/?.lua;' .. package.path
local F = require 'fake_lr'

local photos = {}
for line in io.lines(arg[1]) do
    local f = {}
    for field in (line .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = field end
    local keywords = {}
    for kw in (f[5] or ''):gmatch('[^|]+') do keywords[#keywords + 1] = kw end
    local photo = F.photo(f[1], { pickStatus = tonumber(f[2]), rating = tonumber(f[3]), caption = f[4] or '',
                                  keywords = keywords })
    if (f[6] or '') ~= '' then photo.props.peopleSet = f[6] end
    photos[#photos + 1] = photo
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
        (p.caption:gsub('\n', '\\n')), table.concat(kws, '|'), p.props.peopleSet or '' }, '\t'), '\n')
end
