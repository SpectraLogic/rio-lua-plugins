--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- make low rez webp thumbnail for jpg; probe original and thumbnail for metdata.

local lib_path = plugin_dir .. "/lib/"
---@type RioUtils
local rio_utils = assert(loadfile(lib_path .. "rio_utils.lua"))()
---@type FfmpegPipeline
local ffmpeg_pipeline = assert(loadfile(lib_path .. "ffmpeg_pipeline.lua"))()
local json = assert(loadfile(lib_path .. "dkjson.lua"))()

local input_path  = input
local proxy_path = rio_utils.create_proxy_name(input_path, "webm", output_path)
local thumbnail_path = rio_utils.create_thumbnail_name(input_path, "webp", output_path)
rio:log_debug("Processing video: " .. tostring(input_path) .. " output: " .. tostring(proxy_path) .. " thumbnail: " .. tostring(thumbnail_path))

local technical_metadata, tech_err = ffmpeg_pipeline.get_video_metadata(input_path)
if not technical_metadata then
    rio:log_error("Failed to get technical metadata:" .. tostring(tech_err))
    return
end

local duration = 0
local proxy_meta, proxy_err = ffmpeg_pipeline.make_video_proxy(input_path, proxy_path, "webm")
if not proxy_meta then
   rio:log_error("Failed to create proxy:" .. tostring(proxy_err))
    return
else
    rio:log_info("Created proxy for video: " .. tostring(input_path))
    duration = proxy_meta.duration_seconds or 0
end

local thumbnail_meta, thumbnail_err = ffmpeg_pipeline.make_video_thumbnail(input_path, thumbnail_path, math.floor(duration / 10 + 0.5))
if not thumbnail_meta then
   rio:log_error("Failed to create thumbnail:" .. tostring(thumbnail_err))
else
    rio:log_info("Created thumbnail for video: " .. tostring(input_path))
end

-- coalesce all the metadata
local all_metadata = {}
rio_utils.merge_as_strings(all_metadata, proxy_meta, "proxy_")
rio_utils.merge_as_strings(all_metadata, thumbnail_meta, "thumbnail_")

rio:log_debug("All metadata: " .. json.encode(all_metadata, { indent = true }))
rio:save_metadata(all_metadata)

rio:register_proxy(output_path)
rio:register_thumbnail(thumbnail_path)

rio:log_info("Registered: " .. tostring(output_path))
rio:log_info("Registered: " .. tostring(thumbnail_path))
