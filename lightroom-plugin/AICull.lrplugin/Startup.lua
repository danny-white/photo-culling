--[[
  When Lightroom starts (or the plugin is reloaded): if Culling Bay has phone culls waiting in the
  inbox, offer to apply them. Nothing is applied unless you say Apply; Not now leaves them for next
  time, and Sync AI Cull Data still works as before.

  The offer covers the photos of the shoot folders the waiting rows name, found by walking the
  catalog's folders, so nothing needs selecting first. It applies the phone's file only: the AI's
  pending.tsv can name shoots not imported yet, and a sync moves its input to applied/ whether or
  not every row found a photo, so the AI file waits for Sync AI Cull Data as before. Silent when
  the inbox isn't mounted, holds no phone rows, or none of their shoots are in this catalog.
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

local function offer(context)
    local decPath = LrPathUtils.child(Sync.INBOX, Core.DECISIONS_FILE)
    if LrFileUtils.exists(decPath) ~= 'file' then return end
    local decByKey, decRows = Sync.readFile(decPath, Core.parseDecisionLine)
    if decRows == 0 then return end
    local folders, wanted = Core.foldersOf(decByKey)
    local photos = photosIn(LrApplication.activeCatalog(), wanted)
    if #photos == 0 then return end

    local title, info = Core.offerText(decRows, folders, #photos)
    if LrDialogs.confirm(title, info, 'Apply', 'Not now') ~= 'ok' then return end
    Sync.run(context, { photos = photos, path = decPath, alone = true })
end

LrFunctionContext.postAsyncTaskWithContext('AICullLaunchOffer', function(context)
    LrTasks.sleep(Sync.LAUNCH_DELAY)   -- let the catalog finish opening first
    local ok, err = LrTasks.pcall(offer, context)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Checking for phone culls at launch failed:\n\n' .. tostring(err), 'critical')
    end
end)
