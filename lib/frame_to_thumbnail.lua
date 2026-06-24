local metadata_pipeline = require("metadata_pipeline")

-- Make Proxy, make thumbnail, collect metadata and add metadata
local image_path = arg[1] or "ForSentimentalReasons-Frame-01-00-00-18_302.jpg"
local thumbnail_path = arg[2] or "ForSentimentalReasons-Thumbnail.webp"


print("Creating thumbnail for frame:", image_path, "->", thumbnail_path)

local thumbnail_meta, thumbnail_err = metadata_pipeline.make_thumbnail(image_path, thumbnail_path)
if not thumbnail_meta then
    print("Failed to create thumbnail:", thumbnail_err)
end

return
