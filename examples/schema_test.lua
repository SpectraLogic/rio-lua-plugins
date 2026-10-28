--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--

local json = require("dkjson")
local rio_utils = require("rio_utils")

plugin = {}

function plugin.schema()
  return json.encode({
    -- AWS analysis
      { key = "frames_to_sample",           type = "integer", default = 10,       min = 1, max = 30,   label = "Frames to Sample" },
      { key = "max_tags_per_frame",         type = "integer", default = 20,       min = 1, max = 50,   label = "Max Tags per Frame" },
      { key = "aws_confidence_threshold",   type = "number",  default = 90,       min = 0, max = 100,  label = "AWS Confidence Threshold (%)" },
      { key = "do_transcription",           type = "boolean", default = true,                          label = "Enable Transcription" },
      { key = "do_aws_labels",              type = "boolean", default = true,                          label = "AWS Label Detection" },
      { key = "do_aws_celebrities",         type = "boolean", default = true,                          label = "AWS Celebrity Recognition" },
      { key = "do_aws_faces",               type = "boolean", default = false,                         label = "AWS Face Detection" },
      { key = "do_aws_text",                type = "boolean", default = false,                         label = "AWS Text Detection" },
      { key = "do_aws_moderation",          type = "boolean", default = false,                         label = "AWS Content Moderation" },
      -- Proxy / thumbnail
      { key = "proxy_format",   type = "enum",    default = "mp4",    choices ={"mp4", "webm"}, label = "Proxy Format" },
      { key = "proxy_codec",    type = "enum",    default = "libx264", choices ={"libx264", "libx265", "libvpx-vp9"}, label = "Video Codec" },
      { key = "thumbnail_size", type = "enum",    default = "320x180", choices ={"320x180", "640x360", "1280x720"}, label = "Thumbnail Size" },
      { key = "thumbnail_dpi",  type = "integer", default = 72,                                         label = "Thumbnail DPI" },
      { key = 's3_bucket' ,     type = 'string',  required = 'true',                                    label = 'Temp AWS S3 Bucket' },
  })
end

function plugin.execute()
    local ffmpeg_pipeline = require("ffmpeg_pipeline")
    local ollama = require("ollama_pipeline")
    local whisper = require("whisper_pipeline")
    local aws = require("aws_pipeline")

    local ollama_opts = ollama.make_options_object(settings)
    local ffmpeg_opts = ffmpeg_pipeline.make_options_object(settings)
    local whisper_opts = whisper.make_options_object(settings)
    local aws_opts = aws.make_options_object(settings)

    if not rio_utils.require_settings(settings, { "proxy_format", "proxy_codec" }) then return end

    rio:log_info("Executing plugin on object: " .. tostring(input))
    rio:log_info("Settings: " .. rio_utils.describe_value(settings))
    rio:log_info("AWS options: " .. rio_utils.describe_value(aws_opts))
    rio:log_info("Ollama options: " .. rio_utils.describe_value(ollama_opts))
    rio:log_info("Whisper options: " .. rio_utils.describe_value(whisper_opts))
    rio:log_info("FFmpeg options: " .. rio_utils.describe_value(ffmpeg_opts))

    rio:log_info("Proxy format: " .. tostring(settings.proxy_format) .. " Proxy codec: " .. tostring(settings.proxy_codec))
    local proxy_path = rio_utils.create_proxy_name(input, settings.proxy_format, working_directory)
    rio:log_info("Processing video: " .. tostring(input) .. " output: " .. tostring(proxy_path))
    rio:save_status(rio_utils.get_status_name("completed"), nil)
end
