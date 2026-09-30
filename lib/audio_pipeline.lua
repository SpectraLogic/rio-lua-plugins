--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for audio-only processing in Rio plugin scripts
    REQUIRES: [FFmpeg](https://ffmpeg.org) installed and available in the system PATH.
    REQUIRES: [FFprobe](https://ffmpeg.org/ffprobe.html) installed and available in the system PATH.
    REQUIRES: [ImageMagick](https://imagemagick.org) installed and available in the system PATH.
]]--

local json = require("dkjson")
---@type RioUtils
local rio_utils = require("rio_utils")
---@type MagickPipeline
local magick_pipeline = require("magick_pipeline")

local FFMPEG = "ffmpeg"
local FFPROBE = "ffprobe"

-- proxy_quality presets, keyed by the choice's leading word so the schema can
-- use descriptive choices like "speech (64k mono)" / "music (128k stereo)"
local PROXY_QUALITY_PRESETS = {
    speech = { bitrate = "64k", channels = 1 },
    music = { bitrate = "128k", channels = 2 },
}

local function make_options_object(opts)
    opts = opts or {}
    local quality_key = tostring(opts.proxy_quality or "speech"):lower():match("^%s*(%a+)")
    local quality = PROXY_QUALITY_PRESETS[quality_key] or PROXY_QUALITY_PRESETS.speech
    return {
        proxy_format = opts.proxy_format or "m4a",
        proxy_codec = opts.proxy_codec,
        -- explicit bitrate/channels still win over the quality preset
        proxy_bitrate = opts.proxy_bitrate or quality.bitrate,
        proxy_channels = tonumber(opts.proxy_channels) or quality.channels,
        thumbnail_size = opts.thumbnail_size or "320x180",
        -- sidecar grid: defaults match ffmpeg_pipeline.make_video_sidecar (7x7 of 160x90)
        sidecar_columns = tonumber(opts.sidecar_columns) or 7,
        sidecar_rows = tonumber(opts.sidecar_rows) or 7,
        sidecar_tile_size = opts.sidecar_tile_size or "160x90",
        waveform_color = opts.waveform_color or "0x4FC3F7",
        waveform_background = opts.waveform_background or "#1E1E1E",
        waveform_scale = opts.waveform_scale or "sqrt",  -- lin, log, sqrt, cbrt; sqrt keeps quiet speech visible
    }
end

--- Parse a "WxH" size string into two numbers.
---@param size string  e.g. "320x180"
---@return number|nil width
---@return number|nil height
local function parse_size(size)
    local w, h = tostring(size or ""):match("^(%d+)x(%d+)$")
    return tonumber(w), tonumber(h)
end

-- General support for native aac, libmp3lame, and libopus.
-- this is a separate function so that the calling script could override it to support other codecs
-- or handle different ffmpeg params without a new Rio build.
-- Build with table.insert-after, not `cond and x or nil` entries -- a nil
-- would silently drop every arg after it in the ipairs()-walked table.
local function build_audio_proxy_codec_args(proxy_format, proxy_codec, proxy_bitrate, proxy_channels)
    local bitrate = proxy_bitrate or "64k"
    local codec_args
    if proxy_format == "mp3" then
        codec_args = {
            "-c:a " .. (proxy_codec or "libmp3lame"),
            "-b:a " .. bitrate,
        }
    elseif proxy_format == "ogg" or proxy_format == "opus" or proxy_format == "webm" then
        -- Opus holds up far better than AAC/MP3 at low bitrates (32-48k is fine for speech)
        codec_args = {
            "-c:a " .. (proxy_codec or "libopus"),
            "-b:a " .. bitrate,
        }
    else
        codec_args = {
            "-c:a " .. (proxy_codec or "aac"),
            "-b:a " .. bitrate,
            "-movflags +faststart",
        }
    end
    if proxy_channels then
        table.insert(codec_args, 1, "-ac " .. tostring(proxy_channels))
    end
    return codec_args
end

--- Probe an audio file with ffprobe for technical metadata.
---@param audio_path string  path to the audio file
---@return table|nil metadata  { format, duration_seconds, file_size_bytes, bit_rate, audio_codec, sample_rate, channels, channel_layout, sample_format, title, artist, album }, or nil on failure
---@return string? err
local function get_audio_metadata(audio_path)
    local cmd = rio_utils.join_command({
        FFPROBE,
        "-v quiet",
        "-print_format json",
        "-show_format",
        "-show_streams",
        "-select_streams a:0",
        rio_utils.shell_quote(audio_path),
    })

    local output = rio_utils.run_command(cmd)
    if not output then
        return nil, "ffprobe command failed\n" .. cmd
    end

    local probe_json, _, decode_err = json.decode(output)
    if not probe_json then
        return nil, "Failed to decode ffprobe output: " .. tostring(decode_err) .. "\nraw output: " .. tostring(output)
    end

    local audio_stream = (probe_json.streams or {})[1]
    local format_info = probe_json.format or {}
    local tags = format_info.tags or {}

    return {
        format = format_info.format_name,
        duration_seconds = tonumber(format_info.duration),
        file_size_bytes = tonumber(format_info.size),
        bit_rate = tonumber(format_info.bit_rate),
        audio_codec = audio_stream and audio_stream.codec_name or nil,
        sample_rate = audio_stream and tonumber(audio_stream.sample_rate) or nil,
        channels = audio_stream and tonumber(audio_stream.channels) or nil,
        channel_layout = audio_stream and audio_stream.channel_layout or nil,
        sample_format = audio_stream and audio_stream.sample_fmt or nil,
        -- common embedded tags (ffprobe key case varies by container)
        title = tags.title or tags.TITLE,
        artist = tags.artist or tags.ARTIST,
        album = tags.album or tags.ALBUM,
    }
end

--- Transcode an audio file to a low-bitrate proxy.
--- Codec selection lives with the caller (opts.codec_args, see build_audio_proxy_codec_args).
---@param input_path string  source audio (any container ffmpeg can read; video streams/cover art are dropped)
---@param output_path string  proxy destination (.m4a, .mp3, .ogg, ...)
---@param opts { codec_args: string[] }
---@return table|nil metadata  the proxy's audio metadata, or nil on failure
---@return string? err
local function make_audio_proxy(input_path, output_path, opts)
    opts = opts or {}
    if not opts.codec_args then
        return nil, "make_audio_proxy requires opts.codec_args (see build_audio_proxy_codec_args)"
    end

    local parts = {
        FFMPEG,
        "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-vn",   -- drop embedded cover art, which would otherwise be muxed as a video stream
    }
    for _, arg in ipairs(opts.codec_args) do
        parts[#parts + 1] = arg
    end
    parts[#parts + 1] = rio_utils.shell_quote(output_path)

    local cmd = rio_utils.join_command(parts)
    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg audio proxy command failed\nCommand: " .. cmd
    end
    rio:log_info("Audio proxy command succeeded: " .. tostring(cmd))

    -- exit status is unreliable on the real host (see ffmpeg_pipeline.run_proxy_command),
    -- so verify the output actually carries audio.
    local metadata, meta_err = get_audio_metadata(output_path)
    if not metadata then
        return nil, "ffmpeg audio proxy produced no readable output\n" .. tostring(meta_err) .. "\nCommand: " .. cmd
    end
    if not metadata.audio_codec or not (metadata.duration_seconds and metadata.duration_seconds > 0) then
        return nil, "ffmpeg audio proxy has no audio stream or zero duration\nCommand: " .. cmd
    end
    return metadata
end

--- Build the showwavespic filter for a width x height waveform of the whole file.
local function waveform_filter(width, height, opts)
    return string.format(
        "aformat=channel_layouts=mono,showwavespic=s=%dx%d:colors=%s:scale=%s",
        width, height, opts.waveform_color, opts.waveform_scale
    )
end

--- Render a waveform of the full audio file as a thumbnail.
--- ffmpeg renders a transparent PNG, ImageMagick flattens it onto the background
--- and encodes the final format (from output_path's extension).
---@param input_path string  source audio
---@param output_path string  thumbnail destination (format from extension)
---@param opts? table  see make_options_object (thumbnail_size, waveform_*)
---@return table|nil metadata  the thumbnail's image metadata, or nil on failure
---@return string? err
local function make_waveform_thumbnail(input_path, output_path, opts)
    opts = make_options_object(opts)
    local width, height = parse_size(opts.thumbnail_size)
    if not width then
        return nil, "invalid thumbnail_size: " .. tostring(opts.thumbnail_size)
    end

    local cmd = rio_utils.join_command({
        FFMPEG,
        "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-filter_complex " .. rio_utils.shell_quote(waveform_filter(width, height, opts)),
        "-frames:v 1",
        "-f image2pipe -vcodec png -",
        "| magick png:-",
        "-background " .. rio_utils.shell_quote(opts.waveform_background),
        "-flatten",
        rio_utils.shell_quote(output_path),
    })

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg/magick waveform thumbnail command failed\n" .. cmd
    end

    return magick_pipeline.get_image_metadata(output_path)
end

--- Render the waveform as a columns x rows grid of equal-duration tiles, read
--- left-to-right, top-to-bottom -- the same layout as the video sprite sheet.
--- The waveform is time-linear, so for a click at (x, y):
---     tile = floor(y / tile_height) * columns + floor(x / tile_width)
---     t    = (tile + (x % tile_width) / tile_width) * duration / (columns * rows)
--- With columns = rows = 1 it is a single strip: t = x / width * duration.
---@param input_path string  source audio
---@param output_path string  sidecar destination (format from extension)
---@param opts? table  see make_options_object (sidecar_*, waveform_*)
---@return table|nil grid  { columns, rows, tile_width, tile_height, width, height }, or nil on failure
---@return string? err
local function make_audio_sidecar(input_path, output_path, opts)
    opts = make_options_object(opts)
    local tile_width, tile_height = parse_size(opts.sidecar_tile_size)
    if not tile_width then
        return nil, "invalid sidecar_tile_size: " .. tostring(opts.sidecar_tile_size)
    end
    local columns, rows = opts.sidecar_columns, opts.sidecar_rows
    local tile_count = columns * rows

    -- one long strip, cut into tile_count frames (untile), re-laid out as a grid (tile)
    local filter = waveform_filter(tile_width * tile_count, tile_height, opts) ..
        string.format(",untile=%dx1,tile=%dx%d", tile_count, columns, rows)

    local cmd = rio_utils.join_command({
        FFMPEG,
        "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-filter_complex " .. rio_utils.shell_quote(filter),
        "-frames:v 1",
        "-f image2pipe -vcodec png -",
        "| magick png:-",
        "-background " .. rio_utils.shell_quote(opts.waveform_background),
        "-flatten",
        "-quality 80",
        rio_utils.shell_quote(output_path),
    })

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "audio_pipeline.make_audio_sidecar command failed\n" .. cmd
    end

    if not rio_utils.file_exists(output_path) then
        return nil, "audio_pipeline.make_audio_sidecar reported success but no output file was created\n" .. cmd
    end

    return {
        columns = columns,
        rows = rows,
        tile_width = tile_width,
        tile_height = tile_height,
        width = tile_width * columns,
        height = tile_height * rows,
    }
end


---@class AudioPipeline
---@field get_audio_metadata fun(audio_path: string): table|nil, string? # Probe an audio file for format/duration/codec/sample rate/channels.
---@field make_audio_proxy fun(input_path: string, output_path: string, opts: table): table|nil, string? # Transcode an audio file to a low-bitrate proxy.
---@field make_waveform_thumbnail fun(input_path: string, output_path: string, opts?: table): table|nil, string? # Waveform image of the whole file.
---@field make_audio_sidecar fun(input_path: string, output_path: string, opts?: table): table|nil, string? # Waveform cut into a columns x rows grid of equal-duration tiles.
---@field make_options_object fun(opts?: table): table # Create a defaulted options object for audio_pipeline functions.
---@field build_audio_proxy_codec_args fun(proxy_format: string, proxy_codec?: string, proxy_bitrate?: string, proxy_channels?: number): string[] # Build -c:a/-b:a/etc args for aac, libmp3lame, or libopus. Callers may shadow/wrap this for other codecs without a lib rebuild.
return {
    get_audio_metadata = get_audio_metadata,
    make_audio_proxy = make_audio_proxy,
    make_waveform_thumbnail = make_waveform_thumbnail,
    make_audio_sidecar = make_audio_sidecar,
    make_options_object = make_options_object,
    build_audio_proxy_codec_args = build_audio_proxy_codec_args,
}
