--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- make low rez webp thumbnail for jpg; probe original and thumbnail for metdata.

local lib_path = plugin_dir .. "/lib/"
local rio_utils = assert(loadfile(lib_path .. "rio_utils.lua"))()
local magick_pipeline = assert(loadfile(lib_path .. "magick_pipeline.lua"))()
local json = assert(loadfile(lib_path .. "dkjson.lua"))()

local input_path     = input
local thumbnail_path = rio_utils.create_thumbnail_name(input_path, "jpg", output_path)

local technical_metadata, tech_err = magick_pipeline.get_pdf_metadata(input_path)
if not technical_metadata then
    rio:log_error("Failed to get PDF metadata: " .. tostring(tech_err))
    return
else
    rio:log_info("PDF metadata: " .. json.encode(technical_metadata, { indent = true }))
end

local thumbnail_meta, thumbnail_err = magick_pipeline.make_pdf_thumbnail(input_path, thumbnail_path)
if not thumbnail_meta then
    rio:log_error("Failed to create PDF thumbnail: " .. tostring(thumbnail_err))
    return
else
    rio:log_info("Created thumbnail for PDF: " .. tostring(input_path))
end

-- coalesce metadata (save_metadata requires String values)
local all_metadata = {}
rio_utils.merge_as_strings(all_metadata, technical_metadata)
rio_utils.merge_as_strings(all_metadata, thumbnail_meta, "thumbnail_")

rio:log_debug("All metadata: " .. json.encode(all_metadata, { indent = true }))
rio:save_metadata(all_metadata)

rio:register_thumbnail(thumbnail_path)
rio:log_info("Registered: " .. tostring(thumbnail_path))
