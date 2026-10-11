--[[
  AI Cull Sync -- Lightroom Classic plugin.

  Applies photo_cull's AI color label, keywords and caption, plus your phone culls from
  Culling Bay Mobile (pick/reject flags, Hero stars, burst notes). It never overwrites a flag,
  rating or caption text you set by hand: hidden plugin fields (AICullMetadata.lua) record what
  the plugin itself wrote, and only that is ever replaced. No "Read Metadata from File".
]]
return {
    LrSdkVersion        = 12.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.dannywhite.photocull.aicull',
    LrPluginName        = 'AI Cull Sync',
    LrMetadataProvider  = 'AICullMetadata.lua',
    LrLibraryMenuItems  = {
        {
            title = 'Sync AI Cull Data (AI + phone culls)…',
            file  = 'SyncAICull.lua',
        },
        {
            title = 'AI Semantic Search…',
            file  = 'SemanticSearch.lua',
        },
    },
    VERSION = { major = 2, minor = 0, revision = 0 },
}
