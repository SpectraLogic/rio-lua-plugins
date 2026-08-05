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

local json = require("dkjson")
---@type RioUtils
local rio_utils = require("rio_utils")
---@type MagickPipeline
local magick_pipeline = require("magick_pipeline")

local FFMPEG = "ffmpeg"
local FFPROBE = "ffprobe"
local IS_WINDOWS = os.getenv("OS") == "Windows_NT"


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

local function make_options_object(opts)
    opts = opts or {}
    return {
        frames_to_sample = tonumber(opts.frames_to_sample) or 5,
        max_tags_per_frame = tonumber(opts.max_tags_per_frame) or 15,
        proxy_format = opts.proxy_format or "mp4",
        proxy_codec = opts.proxy_codec or "libx264",
        thumbnail_size = opts.thumbnail_size or "320x180",
        thumbnail_dpi = opts.thumbnail_dpi or 72,
    }
end

--- Probe a video with ffprobe for technical metadata.
---@param video_path string  path to the video file
---@return table|nil metadata  { format, duration_seconds, file_size_bytes, width, height, video_codec, audio_codec, frame_rate, pixel_format, field_order, operational_pattern, start_timecode, umid }, or nil on failure
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
    rio:log_debug("ffprobe raw output: " .. tostring(output))  -- temporary
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
    local tags = format_info.tags or {}

    return {
        format = format_info.format_name,
        duration_seconds = tonumber(format_info.duration),
        file_size_bytes = tonumber(format_info.size),
        width = video_stream and tonumber(video_stream.width) or nil,
        height = video_stream and tonumber(video_stream.height) or nil,
        video_codec = video_stream and video_stream.codec_name or nil,
        audio_codec = audio_stream and audio_stream.codec_name or nil,
        frame_rate = video_stream and rio_utils.parse_ratio(video_stream.avg_frame_rate or video_stream.r_frame_rate) or nil,
        -- pixel format + field order drive proxy decisions (8-bit/4:2:0, deinterlace)
        pixel_format = video_stream and video_stream.pix_fmt or nil,
        field_order = video_stream and video_stream.field_order or nil,
        -- MXF / broadcast container metadata (nil for most formats). operational_pattern
        -- distinguishes OP1a (self-contained) from OP-Atom (split essence); umid links
        -- related OP-Atom essence files for future pairing.
        operational_pattern = tags.operational_pattern_ul,
        start_timecode = tags.timecode,
        umid = tags.material_package_umid,
    }
end

--- Transcode a video to a proxy. The codec is chosen from output_path's extension:
--- mp4 -> H.264/AAC, webm -> VP9/Opus, m3u8 -> HLS single-file. Scaled to max width 1280.
--- For OP-Atom sources, pass opts.extra_audio_inputs (list of mono audio essence paths);
--- they are amerged to stereo via filter_complex.
---@param input_path string  source video
---@param output_path string  proxy destination (.mp4, .webm, or .m3u8)
---@param opts? { deinterlace?: boolean, extra_audio_inputs?: string[], proxy_format?: string }
---@return table|nil metadata  the proxy's video metadata, or nil on failure
---@return string? err
local function make_video_proxy(input_path, output_path, opts)
    opts = opts or {}
    local extra_audio = opts.extra_audio_inputs or {}
    local extension = opts.proxy_format or rio_utils.get_extension(output_path):lower()

    -- Deinterlace (yadif) interlaced sources so the progressive proxy has no combing.
    local scale = "scale='min(1280,iw)':-2"
    local video_filter = opts.deinterlace and ("yadif," .. scale) or scale

    -- codec/output args — no -vf; the video filter is injected separately below
    -- so it can be placed in filter_complex when extra audio inputs require it.
    local codec_args

    if extension == "mp4" then
        codec_args = {
            "-c:v libx264",
            "-preset medium",
            "-crf 23",
            "-pix_fmt yuv420p",  -- 8-bit 4:2:0 so 10-bit/4:2:2 sources (e.g. MXF) stay playable
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
            "-pix_fmt yuv420p",  -- 8-bit 4:2:0 for broad proxy playability
            "-c:a libopus",
            "-b:a 128k",
        }
    elseif extension == "m3u8" then
        -- HLS single-file: all segments in one .ts, playlist uses byte ranges
        codec_args = {
            "-c:v libx264",
            "-preset fast",
            "-crf 23",
            "-pix_fmt yuv420p",
            "-c:a aac",
            "-b:a 128k",
            "-hls_time 6",
            "-hls_flags single_file",
            "-hls_playlist_type vod",
        }
    else
        return nil, "Unsupported video proxy extension: " .. tostring(extension)
    end

    local parts = {FFMPEG, "-y"}

    -- Primary input then any extra OP-Atom audio essence inputs
    parts[#parts + 1] = "-i " .. rio_utils.shell_quote(input_path)
    for _, ap in ipairs(extra_audio) do
        parts[#parts + 1] = "-i " .. rio_utils.shell_quote(ap)
    end

    if #extra_audio > 0 then
        -- OP-Atom multi-audio: combine video filter + audio merge in one filter_complex
        -- so -vf and -filter_complex don't conflict.
        local amix = {}
        for i = 1, #extra_audio do amix[i] = "[" .. i .. ":a:0]" end
        local fc = "[0:v]" .. video_filter .. "[vout];" ..
                   table.concat(amix) .. "amerge=inputs=" .. #extra_audio .. "[aout]"
        parts[#parts + 1] = "-filter_complex " .. rio_utils.shell_quote(fc)
        parts[#parts + 1] = "-map [vout]"
        parts[#parts + 1] = "-map [aout]"
        parts[#parts + 1] = "-ac 2"
    else
        parts[#parts + 1] = "-vf " .. rio_utils.shell_quote(video_filter)
    end

    for _, arg in ipairs(codec_args) do
        parts[#parts + 1] = arg
    end
    parts[#parts + 1] = rio_utils.shell_quote(output_path)

    local cmd = rio_utils.join_command(parts)

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg proxy command failed\nCommand: " .. cmd
    end

    return get_video_metadata(output_path)
end

--- Convert a UMID hex string (e.g. "0x060A2B34...") to the OP-Atom filename convention.
--- OP-Atom essence filenames are the file_package_umid split as 26-6-16-12-4 hex chars
--- joined by hyphens, all lower-case (e.g. "060a2b34...-000000-aabb...-ccdd...-eeff").
---@param umid string  UMID with or without "0x" prefix
---@return string  filename (no directory component)
local function umid_to_filename(umid)
    local hex = umid:gsub("^0[xX]", ""):lower()
    return hex:sub(1,26) .. "-" .. hex:sub(27,32) .. "-" ..
           hex:sub(33,48) .. "-" .. hex:sub(49,60) .. "-" .. hex:sub(61,64)
end

--- Find OP-Atom audio essence files for a video essence file.
--- Primary strategy: read the video file's Data stream tags to get the exact
--- file_package_umid of each referenced audio file, then derive filenames directly.
--- Fallback (e.g. if the video codec prevents ffprobe JSON output): probe every
--- file in the directory and keep those with audio-only streams.
---@param video_path string  path to the OP-Atom video essence file
---@return string[]  sorted list of audio essence file paths (empty if none found)
local function find_op_atom_audio_files(video_path)
    local sep = IS_WINDOWS and "\\" or "/"
    local dir = video_path:match("(.*)[/\\][^/\\]+$") or "."

    -- Primary: derive filenames from Data-stream UMIDs in the video file.
    -- This is faster (one probe) and precise — each video only references its own
    -- paired audio, so multi-quality sets (HD + proxy) stay correctly separated.
    local cmd = rio_utils.join_command({
        FFPROBE, "-v quiet", "-print_format json", "-show_streams",
        rio_utils.shell_quote(video_path),
    })
    local probe_output = rio_utils.run_command(cmd)
    if probe_output then
        local probe_json = (json.decode(probe_output))
        if probe_json and probe_json.streams then
            local audio_files = {}
            for _, stream in ipairs(probe_json.streams) do
                local tags = stream.tags or {}
                if tags.data_type == "audio" and tags.file_package_umid then
                    local filename = umid_to_filename(tags.file_package_umid)
                    local full_path = dir .. sep .. filename
                    if rio_utils.file_exists(full_path) then
                        audio_files[#audio_files + 1] = full_path
                    else
                        rio:log_warn("OP-Atom: referenced audio file not found: " .. full_path)
                    end
                end
            end
            if #audio_files > 0 then
                table.sort(audio_files)
                return audio_files
            end
        end
    end

    -- Fallback: probe every sibling file and keep audio-only ones.
    -- Used when the video codec prevents ffprobe from producing valid JSON.
    rio:log_warn("find_op_atom_audio_files: UMID lookup failed for " .. video_path
        .. "; falling back to directory scan")

    local list_cmd = IS_WINDOWS
        and ("dir /b " .. rio_utils.shell_quote(dir))
        or  ("ls -1 " .. rio_utils.shell_quote(dir))

    local file_list = rio_utils.run_command(list_cmd)
    if not file_list then
        rio:log_warn("find_op_atom_audio_files: could not list directory: " .. dir)
        return {}
    end

    local audio_files = {}
    for filename in file_list:gmatch("[^\n\r]+") do
        filename = rio_utils.trim(filename)
        if filename == "" then goto continue end

        local full_path = dir .. sep .. filename
        if full_path == video_path or filename:lower():match("%.aaf$") then
            goto continue
        end

        local meta = get_video_metadata(full_path)
        if meta and meta.audio_codec and not meta.width then
            audio_files[#audio_files + 1] = full_path
        end

        ::continue::
    end

    table.sort(audio_files)
    return audio_files
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
---@param opts { frames_to_sample?: number, image_extension?: string }
---@param frames_to_sample? number  number of frames to sample (default 5)
---@param image_extension? string  frame image extension (default "jpg")
---@return table[]|nil frames  list of { path, timestamp_seconds, timestamp_label, frame_index }, or nil on failure
---@return string? err
local function extract_video_sample_frames(input_path, output_stem, opts)
    opts = opts or {}
    local video_metadata, metadata_err = get_video_metadata(input_path)
    if not video_metadata then
        return nil, metadata_err
    end

    if not video_metadata.duration_seconds or video_metadata.duration_seconds <= 0 then
        return nil, "Video duration is missing or invalid"
    end

    local stem = output_stem or rio_utils.split_file_name(input_path)
    local count = tonumber(opts.frames_to_sample) or 5
    local extension = opts.image_extension or "jpg"
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
--- description plus the most frequent tags as ai_tagN keys, and (when present)
--- celebrities as ai_celebrityN keys kept separate from generic tags.
---@param frame_results table[]  per-frame result tables
---@param max_tags? number  maximum number of tags to keep (default 15)
---@return table  aggregated metadata { ai_description, ai_tag1..N, ai_celebrity1..N }
local function aggregate_frame_results(frame_results, max_tags)
    local tag_counts = {}
    local first_seen = {}
    local descriptions = {}
    local seen_order = 0

    -- keyed by lowercase name; value = { name = "Jason Momoa", count = N, order = N }
    local celebrity_data = {}
    local celebrity_order = 0

    -- first pass: collect celebrity names so they can be excluded from the tag pass
    local celebrity_names = {}
    for _, item in ipairs(frame_results or {}) do
        for _, name in ipairs(type(item.celebrities) == "table" and item.celebrities or {}) do
            celebrity_names[rio_utils.trim(name):lower()] = true
        end
    end

    for _, item in ipairs(frame_results or {}) do
        -- celebrities: track frequency with properly-cased name preserved
        for _, name in ipairs(type(item.celebrities) == "table" and item.celebrities or {}) do
            local clean = rio_utils.trim(name)
            if clean ~= "" then
                local key = clean:lower()
                if not celebrity_data[key] then
                    celebrity_order = celebrity_order + 1
                    celebrity_data[key] = { name = clean, count = 0, order = celebrity_order }
                end
                celebrity_data[key].count = celebrity_data[key].count + 1
            end
        end

        -- tags: skip any name already captured as a celebrity
        for _, tag in ipairs(collect_frame_tags(item)) do
            local clean = rio_utils.trim(tag):lower()
            if clean ~= "" and not celebrity_names[clean] then
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
        sorted_tags[#sorted_tags + 1] = { tag = tag, count = count, order = first_seen[tag] }
    end
    table.sort(sorted_tags, function(left, right)
        if left.count ~= right.count then return left.count > right.count end
        return left.order < right.order
    end)

    local sorted_celebrities = {}
    for _, data in pairs(celebrity_data) do
        sorted_celebrities[#sorted_celebrities + 1] = data
    end
    table.sort(sorted_celebrities, function(left, right)
        if left.count ~= right.count then return left.count > right.count end
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

    for index, celeb in ipairs(sorted_celebrities) do
        metadata["ai_celebrity" .. index] = celeb.name
    end

    return metadata
end

--- Extract 49 frames from a video and create a 7x7 sprite sheet of them.
---@param input_path string  source video
---@param output_path string  sprite sheet destination (format from extension)
---@param duration_seconds? number  duration of the video in seconds
---@return boolean|nil success  true on success, false
---@return string? err
local function make_video_sidecar(input_path, output_path, duration_seconds)
    rio:log_debug("Creating video sprites for video: " .. tostring(input_path) .. " at : " .. tostring(output_path) .. " duration: " .. tostring(duration_seconds))
    local fps = 49 / (duration_seconds or 1)
    local cmd = rio_utils.join_command({
        FFMPEG,
        "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-frames:v 1",
        "-vf " .. rio_utils.shell_quote("fps=" .. tostring(fps) .. ",scale=160:90,tile=7x7"),
        "-f image2pipe -vcodec png -",
        "| magick png:- -quality 80",
        rio_utils.shell_quote(output_path),
    })

    if not rio_utils.run_quiet_command(cmd) then
        return false, "ffmpeg.make_video_sidecar command failed\n" .. cmd
    end

    if not rio_utils.file_exists(output_path) then
        return false, "ffmpeg.make_video_sidecar reported success but no output file was created\n" .. cmd
    end

    return true, nil
end


---@class FfmpegPipeline
---@field get_video_metadata fun(video_path: string): table|nil, string? # Probe a video for format/duration/codecs/dimensions.
---@field make_video_proxy fun(input_path: string, output_path: string, opts?: table): table|nil, string? # Transcode to an mp4, webm, or m3u8 proxy.
---@field make_video_thumbnail fun(input_path: string, output_path: string, time_offset?: string|number): table|nil, string? # Single-frame video thumbnail.
---@field extract_video_sample_frames fun(input_path: string, output_stem?: string, opts?: table): table[]|nil, string? # Evenly-spaced sample frames.
---@field aggregate_frame_results fun(frame_results: table[], max_tags?: number): table # Combine per-frame AI results into one metadata map.
---@field make_video_sidecar fun(input_path: string, output_path: string, duration_seconds?: number): boolean|nil, string? # Create a 7x7 sprite sheet of frames from a video.
---@field find_op_atom_audio_files fun(video_path: string): string[] # Find OP-Atom audio essence files in the same directory as a video essence file.
---@field make_options_object fun(opts?: table): table # Create a defaulted options object for ffmpeg_pipeline functions.
return {
    get_video_metadata = get_video_metadata,
    make_video_proxy = make_video_proxy,
    make_video_thumbnail = make_video_thumbnail,
    extract_video_sample_frames = extract_video_sample_frames,
    aggregate_frame_results = aggregate_frame_results,
    make_video_sidecar = make_video_sidecar,
    find_op_atom_audio_files = find_op_atom_audio_files,
    make_options_object = make_options_object,
}


--[[
DURATION=$(ffprobe -v error -select_streams v:0 \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 input.mp4)

ffmpeg -i input.mp4 \
  -vf "fps=49/${DURATION},scale=160:90,tile=7x7" \
  -frames:v 1 \
  -c:v libwebp -quality 80 \
  sprites.webp

]]--