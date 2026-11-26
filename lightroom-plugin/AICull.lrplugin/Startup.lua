--[[
  When Lightroom starts (or the plugin is reloaded): if Culling Bay has phone culls or People
  keywords waiting in the inbox, offer to apply them. Nothing is applied unless you say Apply; Not
  now leaves them for next time, and Sync AI Cull Data still works as before.

  Phone culls: the offer covers the photos of the shoot folders the waiting rows name, found by
  walking the catalog's folders, so nothing needs selecting first. It applies the phone's file
  only: the AI's pending.tsv can name shoots not imported yet, and a sync moves its input to
  applied/ whether or not every row found a photo, so the AI file waits for Sync AI Cull Data as
  before.

  People: people.tsv stays in the inbox after a sync (it is the whole current state, and a sync of
  part of the library must not use it up), so it is always there. The offer counts a photo as
  waiting only when the names Culling Bay has for it differ from the names this plugin set last
  time (a bulk read, no per-photo calls), and says nothing when none do. It applies people.tsv to
  those photos alongside the phone culls, or alone when there are no phone culls.

  Silent when the inbox isn't mounted, holds nothing waiting, or none of the shoots are in this
  catalog.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFileUtils       = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'
local LrTasks           = import 'LrTasks'

local Core = require 'CullCore'
local Sync = require 'Sync'

-- Every photo in a folder whose name is in `wanted`, anywhere in the catalog's folder tree.
local function photosIn(catalog, wanted)
    local photos = {}
    local function walk(folder)
        if wanted[folder:getName()] then
            for _, photo in ipairs(folder:getPhotos(false)) do photos[#photos + 1] = photo end
        end
        for _, child in ipairs(folder:getChildren()) do walk(child) end
    end
    for _, top in ipairs(catalog:getFolders()) do walk(top) end
    return photos
end

-- The photos in `a` and `b`, each once.
local function union(a, b)
    local out, seen = {}, {}
    for _, list in ipairs({ a, b }) do
        for _, photo in ipairs(list) do
            if not seen[photo] then
                seen[photo] = true
                out[#out + 1] = photo
            end
        end
    end
    return out
end

local function readIfPresent(name, parseLine)
    local path = LrPathUtils.child(Sync.INBOX, name)
    if LrFileUtils.exists(path) ~= 'file' then return path, {}, 0 end
    local byKey, rows = Sync.readFile(path, parseLine)
    return path, byKey, rows
end

local function offer(context)
    local catalog = LrApplication.activeCatalog()
    local decPath, decByKey, decRows = readIfPresent(Core.DECISIONS_FILE, Core.parseDecisionLine)
    local peoplePath, peopleByKey, peopleRows = readIfPresent(Core.PEOPLE_FILE, Core.parsePeopleLine)
    if decRows == 0 and peopleRows == 0 then return end

    -- Phone culls waiting: the photos of the shoots the rows name.
    local folders, photos = {}, {}
    if decRows > 0 then
        local wanted
        folders, wanted = Core.foldersOf(decByKey)
        photos = photosIn(catalog, wanted)
    end
    local culls = decRows > 0 and #photos > 0

    -- People waiting: photos whose names are not what this plugin set last time.
    local peoplePhotos, nPeople = {}, 0
    if peopleRows > 0 then
        local _, wanted = Core.foldersOf(peopleByKey)
        peoplePhotos, nPeople = Sync.peopleWaiting(catalog, photosIn(catalog, wanted), peopleByKey)
    end
    if not culls and nPeople == 0 then return end

    local title, info = Core.offerText(culls and decRows or 0, folders, #photos, nPeople)
    if LrDialogs.confirm(title, info, 'Apply', 'Not now') ~= 'ok' then return end
    if culls then
        Sync.run(context, { photos = union(photos, peoplePhotos), path = decPath, alone = true,
                            people = nPeople > 0 and peoplePath or nil })
    else
        Sync.run(context, { photos = peoplePhotos, path = peoplePath, alone = true })
    end
end

LrFunctionContext.postAsyncTaskWithContext('AICullLaunchOffer', function(context)
    LrTasks.sleep(Sync.LAUNCH_DELAY)   -- let the catalog finish opening first
    local ok, err = LrTasks.pcall(offer, context)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Checking for phone culls and people at launch failed:\n\n' .. tostring(err), 'critical')
    end
end)
