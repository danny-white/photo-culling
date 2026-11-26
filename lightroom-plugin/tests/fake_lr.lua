--[[
  A small fake of the Lightroom SDK, enough to run SyncAICull.lua under plain Lua 5.1. It is
  strict where Lightroom is strict (catalog writes only inside withWriteAccessDo, no nesting, no
  yield while writing), so a script that passes here at least uses the SDK in the right order.
  It cannot prove Lightroom's own behaviour; the scratch-catalog checklist does that.
]]
local F = {}

local inWrite = false
F.writes = 0           -- catalog changes made so far, so a test can tell "wrote nothing" from "wrote the same"
F.keywordReads = 0     -- photos whose keywords were read
local function needWrite(what)
    if not inWrite then error(what .. ' called outside withWriteAccessDo', 2) end
    F.writes = F.writes + 1
end

-- the plugin's hidden fields, read from the plugin itself so the fake accepts exactly those
local declared = {}
do
    local chunk = assert(loadfile('lightroom-plugin/AICull.lrplugin/AICullMetadata.lua'),
        'fake: run from the repo root')
    for _, field in ipairs(chunk().metadataFieldsForPhotos) do declared[field.id] = field end
end
F.declaredFields = declared

-- keywords ---------------------------------------------------------------------------------
-- An LrKeyword: getName() is the keyword's own name, getParent() the keyword above it (nil at the
-- top). `full` ("People > Alex") is the fake's own handle, and what Photo.keywords is keyed by.
-- Lightroom keeps one keyword per name under a parent and ignores case when it looks one up.
local Keyword = {}
Keyword.__index = Keyword
function Keyword:getName() return self.leaf end
function Keyword:getParent() return self.parent end

local registry = {}      -- lower-case full name -> keyword
local function makeKeyword(name, include, parent)
    local full = (parent and parent.full .. ' > ' or '') .. name
    local kw = registry[full:lower()]
    if not kw then
        kw = setmetatable({ full = full, leaf = name, parent = parent, includeOnExport = include }, Keyword)
        registry[full:lower()] = kw
    end
    return kw
end
-- Keywords that exist before the sync, outside any write access: "People > Pat" is Pat under People.
local function keywordByPath(full)
    local parent
    for part in full:gmatch('[^>]+') do
        part = part:match('^%s*(.-)%s*$')
        parent = makeKeyword(part, true, parent)
    end
    return parent
end

-- photos -----------------------------------------------------------------------------------
local Photo = {}
Photo.__index = Photo

-- t.keywords: the keywords the photo has before the sync, as full names ("Family", "People > Pat").
function F.photo(path, t)
    t = t or {}
    local photo = setmetatable({
        path = path, virtual = t.virtual or false,
        caption = t.caption or '', pickStatus = t.pickStatus or 0, rating = t.rating,
        label = '', keywords = {}, kwObjs = {}, props = {},
    }, Photo)
    for _, full in ipairs(t.keywords or {}) do
        local kw = keywordByPath(full)
        photo.keywords[kw.full], photo.kwObjs[kw.full] = true, kw
    end
    return photo
end

function Photo:getRawMetadata(k)
    if k == 'path' then return self.path end
    if k == 'pickStatus' then return self.pickStatus end
    if k == 'rating' then return self.rating end
    if k == 'isVirtualCopy' then return self.virtual end
    if k == 'keywords' then       -- an array of LrKeyword, only those on the photo itself
        F.keywordReads = F.keywordReads + 1
        local list = {}
        for _, kw in pairs(self.kwObjs) do list[#list + 1] = kw end
        table.sort(list, function(a, b) return a.full < b.full end)
        return list
    end
    error('fake: unknown raw key ' .. k)
end
function Photo:getFormattedMetadata(k)
    if k == 'caption' then return self.caption end
    if k == 'fileName' then return self.path:match('([^/]+)$') end
    error('fake: unknown formatted key ' .. k)
end
function Photo:setRawMetadata(k, v)
    needWrite('setRawMetadata')
    if k == 'caption' then self.caption = v
    elseif k == 'label' then self.label = v
    elseif k == 'pickStatus' then
        assert(v == 1 or v == 0 or v == -1, 'bad pickStatus')
        self.pickStatus = v
    elseif k == 'rating' then
        assert(v == nil or (type(v) == 'number' and v >= 0 and v <= 5), 'bad rating')
        self.rating = v
    else error('fake: setRawMetadata ' .. k) end
end
function Photo:getPropertyForPlugin(plugin, f) assert(plugin == _PLUGIN); return self.props[f] end
function Photo:setPropertyForPlugin(plugin, f, v)
    needWrite('setPropertyForPlugin')
    assert(plugin == _PLUGIN)
    assert(declared[f], 'undeclared field ' .. tostring(f))
    assert(v == nil or type(v) == 'string', 'plugin fields are strings')
    self.props[f] = v
end
function Photo:addKeyword(kw)
    needWrite('addKeyword')
    assert(getmetatable(kw) == Keyword, 'fake: addKeyword wants an LrKeyword')
    self.keywords[kw.full], self.kwObjs[kw.full] = true, kw
end
function Photo:removeKeyword(kw)
    needWrite('removeKeyword')
    assert(getmetatable(kw) == Keyword, 'fake: removeKeyword wants an LrKeyword')
    if not self.keywords[kw.full] then error('fake: keyword not on photo') end  -- be strict
    self.keywords[kw.full], self.kwObjs[kw.full] = nil, nil
end

-- folders ----------------------------------------------------------------------------------
local Folder = {}
Folder.__index = Folder
function F.folder(name, children, photos)
    return setmetatable({ name = name, children = children or {}, photos = photos or {} }, Folder)
end
function Folder:getName() return self.name end
function Folder:getChildren() return self.children end
function Folder:getPhotos(includeChildren) assert(includeChildren == false, 'fake: only direct photos'); return self.photos end

-- catalog ----------------------------------------------------------------------------------
local catalog = { photos = {}, keywords = {}, collections = {}, folders = {} }
function catalog:getTargetPhotos() return self.photos end
function catalog:getFolders() return self.folders end
function catalog:batchGetRawMetadata(photos, keys)
    local out = {}
    for _, p in ipairs(photos) do
        local r = {}
        for _, k in ipairs(keys) do r[k] = p:getRawMetadata(k) end
        out[p] = r
    end
    return out
end
function catalog:batchGetFormattedMetadata(photos, keys)
    local out = {}
    for _, p in ipairs(photos) do
        local r = {}
        for _, k in ipairs(keys) do r[k] = p:getFormattedMetadata(k) end
        out[p] = r
    end
    return out
end
function catalog:batchGetPropertyForPlugin(photos, plugin, fields)
    local out = {}
    for _, p in ipairs(photos) do
        local r = {}
        for _, f in ipairs(fields) do r[f] = p:getPropertyForPlugin(plugin, f) end
        out[p] = r
    end
    return out
end
function catalog:withWriteAccessDo(name, fn)
    if inWrite then error('nested withWriteAccessDo') end
    inWrite = true
    local ok, err = pcall(fn)
    inWrite = false
    if not ok then error(err, 0) end
end
function catalog:createKeyword(name, syn, include, parent, returnExisting)
    needWrite('createKeyword')
    assert(parent == nil or getmetatable(parent) == Keyword, 'fake: createKeyword wants an LrKeyword parent')
    local kw = makeKeyword(name, include, parent)
    self.keywords[kw.full] = kw
    return kw
end
function catalog:createSmartCollection(name, desc, parent, canReturnPrior)
    needWrite('createSmartCollection')
    self.collections[name] = self.collections[name] or desc
    return self.collections[name]
end
F.catalog = catalog

-- the rest of the SDK ----------------------------------------------------------------------
F.dialog = { answers = {}, messages = {}, confirms = {}, openPath = nil }
local modules = {
    LrApplication = { activeCatalog = function() return catalog end },
    LrDate = {
        currentTime = function() return 0 end,
        timeToUserFormat = function() F.stampN = (F.stampN or 0) + 1; return string.format('20261010-12000%d', F.stampN) end,
    },
    LrDialogs = {
        message = function(title, msg) F.dialog.messages[#F.dialog.messages + 1] = title .. ': ' .. (msg or '') end,
        confirm = function(title, msg)
            F.dialog.confirms[#F.dialog.confirms + 1] = title
            return table.remove(F.dialog.answers, 1) or 'ok'
        end,
        runOpenPanel = function() return { F.dialog.openPath } end,
    },
    LrTasks = {
        pcall = pcall,
        yield = function() if inWrite then error('yield inside write access') end end,
        sleep = function() if inWrite then error('sleep inside write access') end end,
    },
    LrFunctionContext = { postAsyncTaskWithContext = function(_, fn) fn({}) end },
    LrProgressScope = setmetatable({}, { __call = function()
        return { setCancelable = function() end, setCaption = function() end,
                 setPortionComplete = function() end, isCanceled = function() return false end,
                 done = function() end }
    end }),
    LrFileUtils = {
        exists = function(p) local f = io.open(p, 'r'); if f then f:close(); return 'file' end; return false end,
        createDirectory = function(p) os.execute('mkdir -p "' .. p .. '"') end,
        delete = function(p) return os.remove(p) ~= nil end,
    },
    LrPathUtils = {
        parent = function(p) return (p:gsub('/[^/]*$', '')) end,
        child = function(p, c) return p .. '/' .. c end,
        leafName = function(p) return p:match('([^/]+)$') end,
    },
}
function import(name) return assert(modules[name], 'fake: no module ' .. name) end
_PLUGIN = { id = 'com.dannywhite.photocull.aicull' }

return F
