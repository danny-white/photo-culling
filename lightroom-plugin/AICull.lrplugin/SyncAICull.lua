--[[
  Library > Plug-in Extras > Sync AI Cull Data: the selected photos ("All Photographs" for a full
  sync), and an inbox file you pick. The work, and the rules for what it will and won't
  overwrite, are in Sync.lua and CullCore.lua.
]]

local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks           = import 'LrTasks'

local Sync = require 'Sync'

LrFunctionContext.postAsyncTaskWithContext('AICullSync', function(context)
    local ok, errOrResult = LrTasks.pcall(Sync.run, context)
    if not ok then
        LrDialogs.message('AI Cull Sync -- error', 'Something went wrong:\n\n' .. tostring(errOrResult), 'critical')
    end
end)
