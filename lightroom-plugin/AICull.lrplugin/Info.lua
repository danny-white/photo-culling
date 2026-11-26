--[[
  AI Cull Sync -- Lightroom Classic plugin.

  Applies photo_cull's AI keywords and caption (never a colour label), plus your phone culls from
  Culling Bay Mobile (pick/reject flags, stars, burst notes) and the people you named there (as
  People > name keywords), and offers waiting phone culls and people when Lightroom starts. It
  never overwrites a flag,
  rating or caption text you set by hand, and never removes a keyword it did not add: hidden
  plugin fields (AICullMetadata.lua) record what the plugin itself wrote, and only that is ever
  replaced. No "Read Metadata from File".
]]
return {
    LrSdkVersion        = 12.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.dannywhite.photocull.aicull',
    LrPluginName        = 'AI Cull Sync',
    LrMetadataProvider  = 'AICullMetadata.lua',
    LrInitPlugin        = 'Startup.lua',     -- offers waiting phone culls when Lightroom starts
    LrForceInitPlugin   = true,              -- ...which needs the plugin loaded at launch, not on first use
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
    VERSION = { major = 2, minor = 3, revision = 0 },
}
