--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- make low rez thumbnail of static images; probe original and thumbnail for metadata.
-- send original image to AWS for analysis.

local json = require("dkjson")

plugin = {}

function plugin.schema()
  return json.encode({
    -- Proxy / thumbnail
      { key = "thumbnail_format", type = "enum",    default = "jpg",     choices ={"jpg", "webp", "png"},             label = "Thumbnail Format" },
      { key = "thumbnail_size",   type = "enum",    default = "320x180", choices ={"320x180", "640x360", "1280x720"}, label = "Thumbnail Size" },
      { key = "thumbnail_dpi",    type = "integer", default = 72,                                                     label = "Thumbnail DPI" },
      { key = "preview_format",   type = "enum",    default = "jpg",     choices ={"jpg", "webp", "png"},             label = "Preview Format" },
      { key = "preview_size",     type = "enum",    default = "640x360", choices ={"320x180", "640x360", "1280x720"}, label = "Preview Size" },
      { key = "preview_dpi",      type = "integer", default = 72,                                                     label = "Preview DPI" },
    -- AWS analysis
      { key = "max_tags_per_frame",         type = "integer", default = 20,       min = 1, max = 50,   label = "Max Tags per Frame" },
      { key = "aws_confidence_threshold",   type = "integer",  default = 90,      min = 0, max = 100,  label = "AWS Confidence Threshold (%)" },
      { key = "do_transcription",           type = "boolean", default = true,                          label = "Enable Transcription" },
      { key = "do_aws_labels",              type = "boolean", default = true,                          label = "AWS Label Detection" },
      { key = "do_aws_celebrities",         type = "boolean", default = true,                          label = "AWS Celebrity Recognition" },
      { key = "do_aws_faces",               type = "boolean", default = false,                         label = "AWS Face Detection" },
      { key = "do_aws_text",                type = "boolean", default = false,                         label = "AWS Text Detection" },
      { key = "do_aws_moderation",          type = "boolean", default = false,                         label = "AWS Content Moderation" },
  })
end

function plugin.execute()
    ---@type RioUtils
    local rio_utils = require("rio_utils")
    ---@type MagickPipeline
    local magick_pipeline = require("magick_pipeline")
    local aws = require("aws_pipeline")

    local magick_opts = magick_pipeline.make_options_object(settings)
    local aws_opts = aws.make_options_object(settings)
    local thumbnail_path = rio_utils.create_thumbnail_name(input, magick_opts.thumbnail_format, working_directory)

    rio:log_info("Processing image: " .. tostring(input))
    rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("initializing"), nil)

    -- probe source file with imageMagick to get technical metadata
    local technical_metadata, tech_err = magick_pipeline.get_image_metadata(input)
    if not technical_metadata then
        rio:log_warn("Failed to get technical metadata:" .. tostring(tech_err))
    else
        rio:log_debug("Technical metadata: " .. json.encode(technical_metadata, { indent = true }))
    end

    -- create low-res thumbnail
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("active"), nil)
    local thumbnail_meta, thumbnail_err = magick_pipeline.make_thumbnail(input, thumbnail_path, magick_opts)
    if not thumbnail_meta then
        rio:log_error("Failed to create thumbnail:" .. tostring(thumbnail_err))
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("failure"), tostring(thumbnail_err))
        rio:save_status(rio_utils.get_status_name("failure"), tostring(thumbnail_err))
        return
    else
        rio:log_debug("Thumbnail metadata: " .. json.encode(thumbnail_meta, { indent = true }))
        rio:register_thumbnail(thumbnail_path)
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("completed"), nil)
    end

    -- create preview
    rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("active"), nil)
    local preview_path = rio_utils.create_preview_name(input, magick_opts.preview_format, working_directory)
    local preview_meta, preview_err = magick_pipeline.make_preview(input, preview_path, magick_opts)
    if not preview_meta then
        rio:log_error("Failed to create preview:" .. tostring(preview_err))
        rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("failure"), tostring(preview_err))
        rio:save_status(rio_utils.get_status_name("failure"), tostring(preview_err))
        return
    else
        rio:log_debug("Preview metadata: " .. json.encode(preview_meta, { indent = true }))
        rio:register_preview(preview_path)
        rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("completed"), nil)
    end

    -- coalesce all the technical metadata
    local all_metadata = {}
    if technical_metadata then
        rio_utils.merge_as_strings(all_metadata, technical_metadata)
    end
    if thumbnail_meta then
        rio_utils.merge_as_strings(all_metadata, thumbnail_meta, "thumbnail_")
    end
    if preview_meta then
        rio_utils.merge_as_strings(all_metadata, preview_meta, "preview_")
    end
    rio:log_debug("All metadata: " .. json.encode(all_metadata, { indent = true }))
    rio:save_technical_metadata(all_metadata)

    -- aws descibe image
    rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("active"), nil)
    local description, description_err = aws.describe_image(input, aws_opts.s3_bucket, aws_opts)
    if not description then
        rio:log_error("Failed to describe image:" .. tostring(description_err))
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), tostring(description_err))
        rio:save_status(rio_utils.get_status_name("failure"), tostring(description_err))
        return
    else
        rio:log_debug("AI description: " .. json.encode(description, { indent = true }))
        rio:save_ai_metadata(description)
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("completed"), nil)
    end

    rio:save_status(rio_utils.get_status_name("completed"), nil)
end
 