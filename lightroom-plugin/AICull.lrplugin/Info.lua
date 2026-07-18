--[[
  AI Cull Sync -- Lightroom Classic plugin.

  Merges photo_cull's AI keywords + color label into your catalog WITHOUT ever touching your
  star ratings or pick/reject flags. It reads a TSV written by:
      photo_cull.py export --plugin-data aicull.tsv --folder <shoot>
  and applies only `label` (color) + keywords to the selected photos. No "Read Metadata from
  File", so nothing you set by hand is overwritten.
]]
return {
    LrSdkVersion        = 12.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.dannywhite.photocull.aicull',
    LrPluginName        = 'AI Cull Sync',
    LrLibraryMenuItems  = {
        {
            title = 'Sync AI Cull Data (keywords + color label)…',
            file  = 'SyncAICull.lua',
        },
    },
    VERSION = { major = 1, minor = 0, revision = 0 },
}
