--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--

local json = require("dkjson")

plugin = {}

function plugin.schema()
  return json.encode({
    -- AWS analysis
      { key = "frames_to_sample",           type = "integer", default = 10,       min = 1, max = 30,   label = "Frames to Sample" },
      { key = "max_tags_per_frame",         type = "integer", default = 20,       min = 1, max = 50,   label = "Max Tags per Frame" },
      { key = "aws_confidence_threshold",   type = "integer",  default = 90,      min = 0, max = 100,  label = "AWS Confidence Threshold (%)" },
      { key = "do_transcription",           type = "boolean", default = true,                          label = "Enable Transcription" },
      { key = "do_aws_labels",              type = "boolean", default = true,                          label = "AWS Label Detection" },
      { key = "do_aws_celebrities",         type = "boolean", default = true,                          label = "AWS Celebrity Recognition" },
      { key = "do_aws_faces",               type = "boolean", default = false,                         label = "AWS Face Detection" },
      { key = "do_aws_text",                type = "boolean", default = false,                         label = "AWS Text Detection" },
      { key = "do_aws_moderation",          type = "boolean", default = false,                         label = "AWS Content Moderation" },
      -- Proxy / thumbnail
      { key = "proxy_format",   type = "enum",    default = "mp4",    choices ={"mp4", "webm"},        label = "Proxy Format" },
      { key = "proxy_codec",    type = "enum",    default = "libx264", choices ={"libx264", "libx265", "libvpx-vp9"}, label = "Video Codec" },
      { key = "thumbnail_format", type = "enum",   default = "jpg",     choices ={"jpg", "webp", "png"},             label = "Thumbnail Format" },
      { key = "thumbnail_size", type = "enum",    default = "320x180", choices ={"320x180", "640x360", "1280x720"}, label = "Thumbnail Size" },
      { key = "thumbnail_dpi",  type = "integer", default = 72,                                        label = "Thumbnail DPI" },
  })
end

function plugin.execute()

    local rio_utils = require("rio_utils")
    local ffmpeg_pipeline = require("ffmpeg_pipeline")
    local aws = require("aws_pipeline")
    local whisper = require("whisper_pipeline")

    local aws_options = aws.make_options_object(settings)
    local ffmpeg_opts = ffmpeg_pipeline.make_options_object(settings)

    -- set statuses to "INITIALIZING" for all products
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("initializing"), nil)
    if (settings.do_transcription) then
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("initializing"), nil)
    end

    local proxy_path = rio_utils.create_proxy_name(input, settings.proxy_format, working_directory)
    local thumbnail_path = rio_utils.create_thumbnail_name(input, settings.thumbnail_format, working_directory)
    local sidecar_path = rio_utils.create_sidecar_name(input, settings.thumbnail_format, working_directory)
    rio:log_debug("Processing video: " .. tostring(input) .. " output: " .. tostring(proxy_path) .. " thumbnail: " .. tostring(thumbnail_path) .. " sprite: " .. tostring(sidecar_path))

    local associated_files = rio:get_object_files()
    rio:log_info("Found " .. tostring(#associated_files) .. " associated files")

    local technical_metadata, tech_err = ffmpeg_pipeline.get_op_atom_video_metadata(associated_files)
    if not technical_metadata then
        rio:log_error("Failed to get technical metadata:" .. tostring(tech_err))
    else
        rio:log_debug("Technical metadata: " .. tostring(technical_metadata))
    end

    local duration = 0
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("active"), nil)
    local proxy_meta, proxy_err = ffmpeg_pipeline.make_op_atom_video_proxy(associated_files, proxy_path, ffmpeg_opts)
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
    local sprite_success, sprite_err = ffmpeg_pipeline.make_video_sidecar(proxy_path, sidecar_path, duration)
    if not sprite_success then
        rio:log_error("Failed to create video sidecar:" .. tostring(sprite_err))
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("failure"), tostring(sprite_err))
    else
        rio:log_info("Created video sidecar: " .. tostring(sidecar_path))
        rio:register_sidecar(sidecar_path)
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("completed"), nil)
    end

    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("active"), nil)
    local thumbnail_meta, thumbnail_err = ffmpeg_pipeline.make_video_thumbnail(proxy_path, thumbnail_path, math.floor(duration / 10 + 0.5))
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

    if (settings.do_transcription) then
        -- transcribe audio from the video proxy
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("active"), nil)
        local transcription_result, transcription_err = whisper.transcribe_audio(proxy_path, working_directory)
        if not transcription_result then
            rio:log_error("Failed to transcribe audio:" .. tostring(transcription_err))
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("failure"), tostring(transcription_err))
        else
            rio:save_transcription(transcription_result.text)
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("completed"), nil)
            rio:log_debug("Transcription result: " .. transcription_result.text)
        end
    end

    -- create sample frames and analyze with AWS Rekognition
    rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("active"), nil)
    local sampled_frames = ffmpeg_pipeline.extract_video_sample_frames(proxy_path, working_directory, ffmpeg_opts)
    if not sampled_frames then
        rio:log_error("Failed to sample video frames")
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), "Failed to sample video frames")
        return
    else
        rio:log_info("Sampled frames: " .. json.encode(sampled_frames, { indent = true }))
    end

    local ai_metadata, ai_err = aws.describe_frames(sampled_frames, aws_options.aws_s3_bucket or "jk-av-proxy", aws_options)
    if not ai_metadata then
        rio:log_error("Failed to describe video with AWS Rekognition:" .. tostring(ai_err))
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), tostring(ai_err))
        return
    else
        rio:log_debug(json.encode(ai_metadata, { indent = true }))
    end


    local sample_frame_metadata, sample_frame_errs = ffmpeg_pipeline.aggregate_frame_results(ai_metadata, aws_options.max_tags_per_frame)
    if not sample_frame_metadata then
        rio:log_error("Failed to aggregate frame results:" .. json.encode(sample_frame_errs, { indent = true }))
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), "Failed to aggregate frame results")
        return
    else
        rio:log_debug("AI metadata: " .. json.encode(sample_frame_metadata, { indent = true }))
        rio:save_ai_metadata(sample_frame_metadata)
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("completed"), nil)
    end

    rio:save_status(rio_utils.get_status_name("completed"), nil)
    rio:log_info("Registered: " .. tostring(proxy_path))
    rio:log_info("Registered: " .. tostring(thumbnail_path))
    rio:log_info("Registered: " .. tostring(sidecar_path))

end
