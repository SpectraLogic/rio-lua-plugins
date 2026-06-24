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
local rio_utils = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/rio_utils.lua"))()
local magick_pipeline = assert(loadfile("/Users/jk/sandbox/projects/plugins/lib/magick_pipeline.lua"))()

local FFMPEG = "ffmpeg"
local FFPROBE = "ffprobe"


local function first_stream(streams, codec_type)
    for _, stream in ipairs(streams or {}) do
        if stream.codec_type == codec_type then
            return stream
        end
    end
    return nil
end

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

local function make_video_thumbnail(input_path, output_path, time_offset)
    rio:log_debug("Creating thumbnail for video: " .. tostring(input_path) .. " at : " .. tostring(output_path))
    -- This ffmpeg build has no webp encoder, so ffmpeg extracts + scales the frame
    -- and pipes it as PNG to ImageMagick (which has libwebp) for the final encode.
    -- The output format follows output_path's extension, so this also works for
    -- jpg/png thumbnails without changing the command.
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

return {
    get_video_metadata = get_video_metadata,
    make_video_proxy = make_video_proxy,
    make_video_thumbnail = make_video_thumbnail,
    extract_video_sample_frames = extract_video_sample_frames,
    aggregate_frame_results = aggregate_frame_results,
}

