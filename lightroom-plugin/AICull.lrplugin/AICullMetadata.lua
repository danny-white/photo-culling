--[[
  Hidden per-photo fields AI Cull Sync uses to remember what it wrote, so that it only ever
  replaces its own work. A field with no `title` is internal: Lightroom shows it nowhere. Such a
  field takes no `dataType` either -- giving one ("string") makes Lightroom reject the whole schema
  ("An error occurred while reading the schema") and disable the plug-in. They hold strings or nil.
  Adding or changing this file makes Lightroom ask once to update the catalog.
]]
return {
    metadataFieldsForPhotos = {
        { id = 'aiCaption' },  -- AI sentence last written into Caption, or '[yours]'
        { id = 'cullFlag' },   -- pick/reject flag last set from the phone: '1' or '-1'
        { id = 'cullStars' },  -- star rating last set from the phone (Hero = '5')
    },
    schemaVersion = 1,
}
