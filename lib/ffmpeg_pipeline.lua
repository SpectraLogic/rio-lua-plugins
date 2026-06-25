--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for FFmpeg processing in Rio plugin scripts
    REQUIRES: [FFmpeg](https://ffmpeg.org) installed and available in the system PATH.
    REQUIRES: [FFprobe](https://ffmpeg.org/ffprobe.html) installed and available in the system PATH.
    REQUIRES (For static frame analysis): [ImageMagick](https://imagemagick.org) installed and available in the system PATH.
]]--

local json = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/dkjson.lua"))()
---@type RioUtils
local rio_utils = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/rio_utils.lua"))()
---@type MagickPipeline
local magick_pipeline = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/magick_pipeline.lua"))()

local FFMPEG = "ffmpeg"
local FFPROBE = "ffprobe"


--- Return the first stream of a given codec_type from an ffprobe streams list.
---@param streams table[]|nil  ffprobe `streams` array
---@param codec_type string  e.g. "video" or "audio"
---@return table|nil  the matching stream, or nil
local function first_stream(streams, codec_type)
    for _, stream in ipairs(streams or {}) do
        if stream.codec_type == codec_type then
            return stream
        end
    end
    return nil
end

--- Probe a video with ffprobe for technical metadata.
---@param video_path string  path to the video file
---@return table|nil metadata  { format, duration_seconds, file_size_bytes, width, height, video_codec, audio_codec, frame_rate }, or nil on failure
---@return string? err
local function get_video_metadata(video_path)
    local cmd = rio_utils.join_command({
        FFPROBE,
        "-v quiet",
        "-print_format json",
        "-show_format",
        "-show_streams",
        rio_utils.shell_quote(video_path),
    })

    local output = rio_utils.run_command(cmd)
    if not output then
        return nil, "ffprobe command failed\n" .. cmd
    end

    local probe_json, _, decode_err = json.decode(output)
    if not probe_json then
        return nil, "Failed to decode ffprobe output: " .. tostring(decode_err)
    end

    local video_stream = first_stream(probe_json.streams, "video")
    local audio_stream = first_stream(probe_json.streams, "audio")
    local format_info = probe_json.format or {}

    return {
        format = format_info.format_name,
        duration_seconds = tonumber(format_info.duration),
        file_size_bytes = tonumber(format_info.size),
        width = video_stream and tonumber(video_stream.width) or nil,
        height = video_stream and tonumber(video_stream.height) or nil,
        video_codec = video_stream and video_stream.codec_name or nil,
        audio_codec = audio_stream and audio_stream.codec_name or nil,
        frame_rate = video_stream and rio_utils.parse_ratio(video_stream.avg_frame_rate or video_stream.r_frame_rate) or nil,
    }
end

--- Transcode a video to a proxy. The codec is chosen from output_path's extension:
--- mp4 -> H.264/AAC, webm -> VP9/Opus. Scaled to a max width of 1280.
---@param input_path string  source video
---@param output_path string  proxy destination (.mp4 or .webm)
---@return table|nil metadata  the proxy's video metadata, or nil on failure
---@return string? err
local function make_video_proxy(input_path, output_path)
    local extension = rio_utils.get_file_extension(output_path)
    local codec_args

    if extension == "mp4" then
        codec_args = {
            "-c:v libx264",
            "-preset medium",
            "-crf 23",
            "-c:a aac",
            "-b:a 128k",
            "-movflags +faststart",
        }
    elseif extension == "webm" then
        codec_args = {
            "-c:v libvpx-vp9",
            "-crf 31",
            "-b:v 0",
            "-row-mt 1",        -- row-based multithreading (big win on multicore)
            "-deadline good",   -- 'realtime' is even faster if you need it
            "-cpu-used 5",      -- 0=slowest/best ... 8=fastest; 5 is a good proxy tradeoff
            "-c:a libopus",
            "-b:a 128k",
        }
    else
        return nil, "Unsupported video proxy extension: " .. tostring(extension)
    end

    local parts = {
        FFMPEG,
        "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-vf " .. rio_utils.shell_quote("scale='min(1280,iw)':-2"),
    }
    for _, arg in ipairs(codec_args) do
        parts[#parts + 1] = arg
    end
    parts[#parts + 1] = rio_utils.shell_quote(output_path)

    local cmd = rio_utils.join_command(parts)

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg proxy command failed\n" .. "Command: " .. cmd
    end

    return get_video_metadata(output_path)
end

--- Extract a single frame from a video and encode it as a thumbnail.
--- This ffmpeg build has no webp encoder, so ffmpeg extracts + scales the frame
--- and pipes it as PNG to ImageMagick (which has libwebp) for the final encode.
--- The output format follows output_path's extension (also works for jpg/png).
---@param input_path string  source video
---@param output_path string  thumbnail destination (format from extension)
---@param time_offset? string|number  seek position in ffmpeg time syntax or seconds (default "00:00:01")
---@return table|nil metadata  the thumbnail's image metadata, or nil on failure
---@return string? err
local function make_video_thumbnail(input_path, output_path, time_offset)
    rio:log_debug("Creating thumbnail for video: " .. tostring(input_path) .. " at : " .. tostring(output_path))
    local cmd = rio_utils.join_command({
        FFMPEG,
        "-y",
        "-ss " .. rio_utils.shell_quote(time_offset or "00:00:01"),
        "-i " .. rio_utils.shell_quote(input_path),
        "-frames:v 1",
        "-vf " .. rio_utils.shell_quote("scale='min(640,iw)':-2"),
        "-f image2pipe -vcodec png -",
        "| magick -",
        rio_utils.shell_quote(output_path),
    })

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg/magick thumbnail command failed\n" .. cmd
    end

    return magick_pipeline.get_image_metadata(output_path)
end

--- Extract evenly-spaced sample frames across a video's duration.
---@param input_path string  source video
---@param output_stem? string  output filename stem (defaults to the input's stem)
---@param frame_count? number  number of frames to sample (default 5)
---@param image_extension? string  frame image extension (default "jpg")
---@return table[]|nil frames  list of { path, timestamp_seconds, timestamp_label, frame_index }, or nil on failure
---@return string? err
local function extract_video_sample_frames(input_path, output_stem, frame_count, image_extension)
    local video_metadata, metadata_err = get_video_metadata(input_path)
    if not video_metadata then
        return nil, metadata_err
    end

    if not video_metadata.duration_seconds or video_metadata.duration_seconds <= 0 then
        return nil, "Video duration is missing or invalid"
    end

    local stem = output_stem or rio_utils.split_file_name(input_path)
    local count = frame_count or 5
    local extension = image_extension or "jpg"
    local spacing = video_metadata.duration_seconds / (count + 1)
    local frame_records = {}

    for index = 1, count do
        local timestamp_seconds = spacing * index
        local timestamp_label = rio_utils.format_timestamp(timestamp_seconds)
        local output_path = string.format(
            "%s-Frame-%02d-%s.%s",
            stem,
            index,
            rio_utils.format_timestamp_for_filename(timestamp_seconds),
            extension
        )
        local cmd = rio_utils.join_command({
            FFMPEG,
            "-y",
            "-ss " .. rio_utils.shell_quote(timestamp_label),
            "-i " .. rio_utils.shell_quote(input_path),
            "-frames:v 1",
            "-vf " .. rio_utils.shell_quote("scale='min(640,iw)':-2"),
            rio_utils.shell_quote(output_path),
        })

        if not rio_utils.run_quiet_command(cmd) then
            return nil, "ffmpeg frame extraction failed at frame " .. tostring(index)
        end

        frame_records[#frame_records + 1] = {
            path = output_path,
            timestamp_seconds = timestamp_seconds,
            timestamp_label = timestamp_label,
            frame_index = index,
        }
    end

    return frame_records
end

--- Collect tag strings from a frame result, either from a `tags` array or from
--- sequential ai_tag1..ai_tagN keys.
---@param item table  a single frame's result table
---@return string[]  the collected tags
local function collect_frame_tags(item)
    local tags = {}

    if type(item.tags) == "table" then
        for _, tag in ipairs(item.tags) do
            tags[#tags + 1] = tag
        end
        return tags
    end

    for index = 1, 50 do
        local tag = item["ai_tag" .. index]
        if not tag then
            break
        end
        tags[#tags + 1] = tag
    end

    return tags
end

--- Aggregate per-frame AI results into a single metadata map: a representative
--- description plus the most frequent tags as ai_tagN keys.
---@param frame_results table[]  per-frame result tables
---@param max_tags? number  maximum number of tags to keep (default 15)
---@return table  aggregated metadata { ai_description, ai_tag1, ai_tag2, ... }
local function aggregate_frame_results(frame_results, max_tags)
    local tag_counts = {}
    local first_seen = {}
    local descriptions = {}
    local seen_order = 0

    for _, item in ipairs(frame_results or {}) do
        for _, tag in ipairs(collect_frame_tags(item)) do
            local clean = rio_utils.trim(tag):lower()
            if clean ~= "" then
                if not tag_counts[clean] then
                    tag_counts[clean] = 0
                    seen_order = seen_order + 1
                    first_seen[clean] = seen_order
                end
                tag_counts[clean] = tag_counts[clean] + 1
            end
        end

        local description = rio_utils.trim(item.description or item.ai_description)
        if description ~= "" then
            descriptions[#descriptions + 1] = description
        end
    end

    local sorted_tags = {}
    for tag, count in pairs(tag_counts) do
        sorted_tags[#sorted_tags + 1] = {
            tag = tag,
            count = count,
            order = first_seen[tag],
        }
    end

    table.sort(sorted_tags, function(left, right)
        if left.count ~= right.count then
            return left.count > right.count
        end
        return left.order < right.order
    end)

    local top_tags = {}
    local limit = max_tags or 15
    for index = 1, math.min(limit, #sorted_tags) do
        top_tags[#top_tags + 1] = sorted_tags[index].tag
    end

    local metadata = {}
    if #descriptions > 0 then
        metadata.ai_description = descriptions[1]
    elseif #top_tags > 0 then
        metadata.ai_description = "Video appears to feature: " .. table.concat(top_tags, ", ", 1, math.min(8, #top_tags)) .. "."
    else
        metadata.ai_description = "No reliable visual description generated from sampled frames."
    end

    for index, tag in ipairs(top_tags) do
        metadata["ai_tag" .. index] = tag
    end

    return metadata
end

---@class FfmpegPipeline
---@field get_video_metadata fun(video_path: string): table|nil, string? # Probe a video for format/duration/codecs/dimensions.
---@field make_video_proxy fun(input_path: string, output_path: string): table|nil, string? # Transcode to an mp4 or webm proxy.
---@field make_video_thumbnail fun(input_path: string, output_path: string, time_offset?: string|number): table|nil, string? # Single-frame video thumbnail.
---@field extract_video_sample_frames fun(input_path: string, output_stem?: string, frame_count?: number, image_extension?: string): table[]|nil, string? # Evenly-spaced sample frames.
---@field aggregate_frame_results fun(frame_results: table[], max_tags?: number): table # Combine per-frame AI results into one metadata map.

return {
    get_video_metadata = get_video_metadata,
    make_video_proxy = make_video_proxy,
    make_video_thumbnail = make_video_thumbnail,
    extract_video_sample_frames = extract_video_sample_frames,
    aggregate_frame_results = aggregate_frame_results,
}
