--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--

local json = require("dkjson")

plugin = {}

function plugin.schema()
  return json.encode({
      -- AWS Transcribe and Summarize
      { key = 's3_bucket' ,                 type = 'string',  required = 'true',                       label = 'Temp AWS S3 Bucket' },
      { key = "aws_profile",                type = "string",  default = "default",                     label = "AWS Profile" },
      { key = "do_transcription",           type = "boolean", default = true,                          label = "Enable AWS Transcription" },
      { key = "language", type = "string",  default = "en", choices={"en-US","en-AU","en-GB","fr-FR","de-DE","es-ES","es-MX","es-US"}, label = "Language"},
      { key = "max_timeout_seconds" ,       type = "integer", default = 600,                           label = "AWS Transcribe Max Timeout (Seconds)" },
      { key = "do_bedrock_summary",         type = "boolean", default = false,                         label = "Generate AI Summary (Bedrock)" },
      { key = "bedrock_model_id",           type = "string",  default = "us.amazon.nova-2-lite-v1:0",  label = "Bedrock Model ID" },
      { key = "bedrock_region",             type = "string",  default = "us-east-1",                   label = "Bedrock AWS Region" },
      -- Proxy / thumbnail
      { key = "proxy_quality", type = "enum", default = "speech (64k mono)", choices = {"speech (64k mono)", "music (128k stereo)"}, label = "Audio Proxy Quality" },
      { key = "thumbnail_format", type = "enum",   default = "jpg",     choices ={"jpg", "webp", "png"},             label = "Thumbnail Format" },
      { key = "thumbnail_size", type = "enum",    default = "320x180", choices ={"320x180", "640x360", "1280x720"}, label = "Thumbnail Size" },
      { key = "thumbnail_dpi",  type = "integer", default = 72,                                        label = "Thumbnail DPI" },
  })
end

-- override to support other codecs or change parameters from ffmpeg_pipeline's implementation
local build_audio_proxy_codec_args = require("audio_pipeline").build_audio_proxy_codec_args

function plugin.execute()
    ---@type RioUtils
    local rio_utils = require("rio_utils")
    ---@type FfmpegPipeline
    local audio_pipeline = require("audio_pipeline")
    ---@type AwsPipeline
    local aws = require("aws_pipeline")

    local aws_options = aws.make_options_object(settings)
    local audio_opts = audio_pipeline.make_options_object(settings)

    local proxy_path = rio_utils.create_proxy_name(input, 'm4a', working_directory)
    local thumbnail_path = rio_utils.create_thumbnail_name(input, settings.thumbnail_format, working_directory)
    local sidecar_path = rio_utils.create_sidecar_name(input, settings.thumbnail_format, working_directory)
    rio:log_info("Processing audio: " .. 
        tostring(input) .. " output: " ..
        tostring(proxy_path) .. " thumbnail: " ..
        tostring(thumbnail_path) .. " sprite: " ..
        tostring(sidecar_path) .. " working_directory: " ..
        tostring(working_directory))

    -- set statuses to "INITIALIZING" for all products
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("initializing"), nil)
    if (aws_options.do_transcription) then
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("initializing"), nil)
    end
    if (aws_options.do_bedrock_summary) then
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("initializing"), nil)
    end

    local technical_metadata, tech_err = audio_pipeline.get_audio_metadata(input)
    if not technical_metadata then
        rio:log_error("Failed to get technical metadata:" .. tostring(tech_err))
    end

    local duration = 0
    -- use default type (m4a) and codec (aac) 
    audio_opts.codec_args = build_audio_proxy_codec_args(nil, nil)
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("active"), nil)
    local proxy_meta, proxy_err = audio_pipeline.make_audio_proxy(input, proxy_path, audio_opts)
    if not proxy_meta then
        rio:log_error("Failed to create proxy:" .. tostring(proxy_err))
        rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("failure"), tostring(proxy_err))
        -- the rest of the pipline depends on the proxy. B'bye...
        rio:save_status(rio_utils.get_status_name("failure"), tostring(proxy_err))
        return
    else
        rio:log_info("Created proxy: " .. tostring(proxy_path))
        duration = proxy_meta.duration_seconds or 0
        rio:register_proxy(proxy_path)
        rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("completed"), nil)
    end

    rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("active"), nil)
    local sprite_success, sprite_err = audio_pipeline.make_audio_sidecar(proxy_path, sidecar_path, audio_opts)
    if not sprite_success then
        rio:log_error("Failed to create sidecar:" .. tostring(sprite_err))
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("failure"), tostring(sprite_err))
    else
        rio:log_info("Created audio sidecar: " .. tostring(sidecar_path))
        rio:register_sidecar(sidecar_path)
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("completed"), nil)
    end

    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("active"), nil)
    local thumbnail_meta, thumbnail_err = audio_pipeline.make_waveform_thumbnail(proxy_path, thumbnail_path, audio_opts)
    if not thumbnail_meta then
        rio:log_error("Failed to create thumbnail:" .. tostring(thumbnail_err))
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("failure"), tostring(thumbnail_err))
    else
        rio:register_thumbnail(thumbnail_path)
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("completed"), nil)
        rio:log_info("Created thumbnail: " .. tostring(thumbnail_path))
    end

    -- coalesce and save all technical metadata
    local all_technical_metadata = {}
    rio_utils.merge_as_strings(all_technical_metadata, technical_metadata)
    if proxy_meta then
        rio_utils.merge_as_strings(all_technical_metadata, proxy_meta, "proxy_")
    end
    if thumbnail_meta then
        rio_utils.merge_as_strings(all_technical_metadata, thumbnail_meta, "thumbnail_")
    end
    rio:log_debug("All metadata: " .. json.encode(all_technical_metadata, { indent = true }))
    rio:save_technical_metadata(all_technical_metadata)

    -- transcribe audio from the proxy
    local transcription_result
    if (aws_options.do_transcription) then
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("active"), nil)
        local mp3_path = rio_utils.create_mp3_filename(input, working_directory)
        local transcription_err
        transcription_result, transcription_err = aws.transcribe_audio(proxy_path, mp3_path, aws_options.s3_bucket, aws_options)
        if not transcription_result then
            rio:log_error("Failed to transcribe audio:" .. tostring(transcription_err))
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("failure"), tostring(transcription_err))
        else
            rio:log_debug("Transcription result: " .. transcription_result.text)
            rio:save_transcription(transcription_result.text)
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("completed"), nil)
        end
    end

    if aws_options.do_bedrock_summary then
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("active"), nil)
        local summary, summary_err = aws.summarize_clip(
            transcription_result and transcription_result.text,
            nil,
            aws_options
        )
        if summary then
            rio:log_info("Generated AWS summary")
            rio:save_summary(summary)
            rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("completed"), nil)
        else
            rio:log_warn("Failed to generate AWS summary: " .. tostring(summary_err))
            rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), tostring(summary_err))
        end
    end

    rio:save_status(rio_utils.get_status_name("completed"), nil)
end
