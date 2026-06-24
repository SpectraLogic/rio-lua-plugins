--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for Imagemagick and ghostscript processing in Rio plugin scripts
    REQUIRES: [ImageMagick](https://imagemagick.org) installed and available in the system PATH.
    REQUIRES (for PDF): [Ghostscript](https://www.ghostscript.com) installed and available in the system PATH. 
]]--

local json = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/dkjson.lua"))()
local rio_utils = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/rio_utils.lua"))()

local MAGICK = "magick"
local GS = "gs"

local function get_image_metadata(image_path)
    local cmd = MAGICK .. " identify -format " .. rio_utils.shell_quote("%m|%w|%h|%x|%y|%b") .. " " .. rio_utils.shell_quote(image_path)
    local output = rio_utils.run_command(cmd)
    rio:log_debug("Running command: " .. cmd)
    rio:log_debug("Command output: " .. tostring(output))
    if not output then 
        return nil, "magick identify produced no output"
    end

    local fmt, width, height, x_res, y_res, size =
        output:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)")

    if not fmt then
        return nil, "could not parse identify output: " .. output
    end

    local res = rio_utils.parse_num(x_res) or rio_utils.parse_num(y_res)

    return {
        format = fmt,
        width = tonumber(width),
        height = tonumber(height),
        resolution_dpi = res and math.floor(res) or nil,
        file_size_bytes = rio_utils.parse_bytes(size),
    }
end

local function write_derivative(input_path, output_path, resize_geometry, density_dpi)
    local parts = {}
    for _, part in ipairs({
        MAGICK,
        rio_utils.shell_quote(input_path),
        "-auto-orient",
        "-strip",
        "-resize " .. rio_utils.shell_quote(resize_geometry),
        density_dpi and ("-units PixelsPerInch -density " .. tostring(density_dpi)) or nil,
        rio_utils.shell_quote(output_path),
    }) do
        if part then
            parts[#parts + 1] = part
        end
    end

    if not rio_utils.run_quiet_command(rio_utils.join_command(parts)) then
        return nil, "ImageMagick command failed"
    end

    return get_image_metadata(output_path)
end

local function make_thumbnail(image_path, output_path)
    return write_derivative(image_path, output_path, "320x320>", 72)
end

-- PDFs need different handling than write_derivative: -density must precede the
-- input to control rasterization quality, the page is selected with [0], and
-- transparency is flattened onto white so it doesn't render black in JPEG.
local function make_pdf_thumbnail(pdf_path, output_path, density_dpi)
    local parts = {
        MAGICK,
        "-density " .. tostring(density_dpi or 150),
        rio_utils.shell_quote(pdf_path .. "[0]"),
        "-background white",
        "-alpha remove",
        "-auto-orient",
        "-strip",
        "-thumbnail " .. rio_utils.shell_quote("320x320>"),
        rio_utils.shell_quote(output_path),
    }

    if not rio_utils.run_quiet_command(rio_utils.join_command(parts)) then
        return nil, "ImageMagick PDF thumbnail command failed"
    end

    return get_image_metadata(output_path)
end

-- Reads the PDF version straight from the file header (e.g. "%PDF-1.7").
local function read_pdf_version(pdf_path)
    local f = io.open(pdf_path, "rb")
    if not f then return nil end
    local header = f:read(16) or ""
    f:close()
    return header:match("%%PDF%-([%d%.]+)")
end

local function file_size_bytes(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- Extracts document metadata using ghostscript's bundled pdf_info.ps. Invoked by
-- bare name so gs resolves it on its own lib search path (version-independent).
-- No rasterization, so it's fast even for large PDFs.
local function get_pdf_metadata(pdf_path)
    local cmd = rio_utils.join_command({
        GS, "-q", "-dNODISPLAY", "-dNOSAFER",
        "-sFile=" .. rio_utils.shell_quote(pdf_path),
        "pdf_info.ps",
    })

    local output = rio_utils.run_command(cmd)
    if not output or output == "" then
        return nil, "Failed to read PDF info via ghostscript"
    end

    local function field(label)
        local v = output:match(label .. ":%s*([^\r\n]*)")
        if v then v = rio_utils.trim(v) end
        if v == "" then v = nil end
        return v
    end

    local metadata = {
        format            = "PDF",
        pdf_version       = read_pdf_version(pdf_path),
        page_count        = tonumber(output:match("has%s+(%d+)%s+page")),
        title             = field("Title"),
        author            = field("Author"),
        subject           = field("Subject"),
        keywords          = field("Keywords"),
        creator           = field("Creator"),
        producer          = field("Producer"),
        creation_date     = field("CreationDate"),
        modification_date = field("ModDate"),
        file_size_bytes   = file_size_bytes(pdf_path),
    }

    -- First-page dimensions in points (1 pt = 1/72 inch) from the MediaBox.
    local x0, y0, x1, y1 = output:match(
        "Page 1 MediaBox:%s*%[%s*([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s*%]")
    if x0 and x1 then
        metadata.width_points  = tonumber(x1) - tonumber(x0)
        metadata.height_points = tonumber(y1) - tonumber(y0)
    end

    return metadata
end

return {
    get_image_metadata = get_image_metadata,
    make_thumbnail = make_thumbnail,
    make_pdf_thumbnail = make_pdf_thumbnail,
    get_pdf_metadata = get_pdf_metadata,
}

