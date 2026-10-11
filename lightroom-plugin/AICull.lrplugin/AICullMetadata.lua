--[[
  Hidden per-photo fields AI Cull Sync uses to remember what it wrote, so that it only ever
  replaces its own work. None has a `title`, so Lightroom shows none of them in the Metadata
  panel. Adding or changing this file makes Lightroom ask once to update the catalog.
]]
return {
    metadataFieldsForPhotos = {
        { id = 'aiCaption', dataType = 'string' },  -- AI sentence last written into Caption, or '[yours]'
        { id = 'cullFlag',  dataType = 'string' },  -- pick/reject flag last set from the phone: '1' or '-1'
        { id = 'cullStars', dataType = 'string' },  -- star rating last set from the phone (Hero = '5')
    },
    schemaVersion = 1,
}
