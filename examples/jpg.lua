--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- make low rez webp thumbnail for jpg; probe original and thumbnail for metdata.

local lib_path = plugin_dir .. "/lib/"
---@type RioUtils
local rio_utils = assert(loadfile(lib_path .. "rio_utils.lua"))()
---@type MagickPipeline
local magick_pipeline = assert(loadfile(lib_path .. "magick_pipeline.lua"))()
-- local ollama_describe = loadfile(lib_path .. "ollama_describe")
local json = assert(loadfile(lib_path .. "dkjson.lua"))()
local image_path = input
local thumbnail_path = rio_utils.create_thumbnail_name(image_path, "webp", output_path)

rio:log_info("Processing image: " .. tostring(image_path))

-- probe source file with imageMagick to get technical metadata
local technical_metadata, tech_err = magick_pipeline.get_image_metadata(image_path)
if not technical_metadata then
    rio:log_warn("Failed to get technical metadata:" .. tostring(tech_err))
else
    rio:log_debug("Technical metadata: " .. json.encode(technical_metadata, { indent = true }))
end

-- create low-res thumbnail
local thumbnail_meta, thumbnail_err = magick_pipeline.make_thumbnail(image_path, thumbnail_path)
if not thumbnail_meta then
    rio:log_error("Failed to create thumbnail:" .. tostring(thumbnail_err))
    return
else
    rio:log_debug("Thumbnail metadata: " .. json.encode(thumbnail_meta, { indent = true }))
end

--[[ local description, description_err = ollama_describe.describe_image(image_path)
if not description then
    print("Failed to describe image:", description_err)
    return
-- else
--    print(json.encode(description, { indent = true }))
end
]]--

-- coalesce all the metadata
local all_metadata = {}
rio_utils.merge_as_strings(all_metadata, technical_metadata)
rio_utils.merge_as_strings(all_metadata, thumbnail_meta, "thumbnail_")
-- rio_utils.merge_as_strings(all_metadata, description, "ai_")
rio:log_debug("All metadata: " .. json.encode(all_metadata, { indent = true }))

rio:log_info("Registering thumbnail for image: " .. tostring(thumbnail_path))
rio:register_thumbnail(thumbnail_path)
rio:save_metadata(all_metadata)
