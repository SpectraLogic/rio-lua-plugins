--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- make low rez webp thumbnail and preview from PDF; probe original and thumbnail for metadata.

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
  })
end

function plugin.execute()
    ---@type RioUtils
    local rio_utils = require("rio_utils")
    ---@type MagickPipeline
    local magick_pipeline = require("magick_pipeline")

    local magick_settings = magick_pipeline.make_options_object(settings)

    local thumbnail_path = rio_utils.create_thumbnail_name(input, magick_settings.thumbnail_format, working_directory)
    local preview_path = rio_utils.create_preview_name(input, magick_settings.preview_format, working_directory)

    rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("initializing"), nil)

    local technical_metadata, tech_err = magick_pipeline.get_pdf_metadata(input)
    if not technical_metadata then
        rio:log_error("Failed to get PDF metadata: " .. tostring(tech_err))
        rio:save_status(rio_utils.get_status_name("failure"), tostring(tech_err))
        return
    else
        rio:log_info("PDF metadata: " .. json.encode(technical_metadata, { indent = true }))
    end

    -- make thumbnail
    local thumbnail_opts = {
        thumbnail_size = magick_settings.thumbnail_size,
        density_dpi = magick_settings.thumbnail_dpi,
    }
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("active"), nil)
    local thumbnail_meta, thumbnail_err = magick_pipeline.make_pdf_thumbnail(input, thumbnail_path, thumbnail_opts)
    if not thumbnail_meta then
        rio:log_error("Failed to create PDF thumbnail: " .. tostring(thumbnail_err))
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("failure"), tostring(thumbnail_err))
    else
        rio:log_info("Created thumbnail for PDF: " .. tostring(input))
        rio:register_thumbnail(thumbnail_path)
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("completed"), nil)
    end

    -- make preview
    local preview_opts = {
        thumbnail_size = magick_settings.preview_size,
        density_dpi = magick_settings.preview_dpi,
    }
    rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("active"), nil)
    local preview_meta, preview_err = magick_pipeline.make_pdf_thumbnail(input, preview_path, preview_opts)
    if not preview_meta then
        rio:log_error("Failed to create PDF preview: " .. tostring(preview_err))
        rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("failure"), tostring(preview_err))
    else
        rio:log_info("Created preview for PDF: " .. tostring(input))
        rio:register_preview(preview_path)
        rio:product_status(rio_utils.get_product_name("preview"), rio_utils.get_status_name("completed"), nil)
    end

    -- coalesce metadata (save_technical_metadata requires String values)
    local all_metadata = {}
    rio_utils.merge_as_strings(all_metadata, technical_metadata)
    if thumbnail_meta then
        rio_utils.merge_as_strings(all_metadata, thumbnail_meta, "thumbnail_")
    end
    if preview_meta then
        rio_utils.merge_as_strings(all_metadata, preview_meta, "preview_")
    end
    rio:log_debug("All metadata: " .. json.encode(all_metadata, { indent = true }))
    rio:save_technical_metadata(all_metadata)

    rio:save_status(rio_utils.get_status_name("completed"), nil)
    rio:log_info("Registered: " .. tostring(thumbnail_path))
    rio:log_info("Registered: " .. tostring(preview_path))
end
