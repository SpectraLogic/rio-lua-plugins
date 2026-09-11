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

-- General support for popular codecs: libxh264, h264_nvenc, h264_videotoolbox, libvpx-vp9, etc. 
-- this is a separate function so that the calling script could override it to support other codecs
-- or handle different ffmpeg params without a new Rio build.
-- Build with table.insert-after, not a leading `cond and x or nil`
-- entry -- an unset start_timecode would otherwise silently drop every arg
-- after it in the ipairs()-walked table.
local function build_proxy_codec_args(proxy_format, proxy_codec, start_timecode)
    local codec_args
    -- Hardware encoders are checked ahead of proxy_format: each is only
    -- ever meaningful for an mp4/H.264 target, and picking one shouldn't
    -- get silently swapped out just because proxy_format says "webm" --
    -- a mismatched combo should fail loudly in ffmpeg, not get overridden.
    if proxy_codec == "h264_nvenc" then
        -- NVENC has its own param set, distinct from libx264: no -crf/-preset.
        -- -cq is NVENC's quality knob (only honored under -rc vbr); -b:v 0
        -- lets -cq drive quality instead of targeting a bitrate.
        codec_args = {
            "-c:v h264_nvenc",
            "-preset p5",   -- p1 (fastest) .. p7 (slowest/best); p5 balances speed/quality
            "-rc vbr",
            "-cq 23",
            "-b:v 0",
            "-pix_fmt yuv420p",
            "-c:a aac",
            "-b:a 128k",
            "-movflags +faststart",
        }
    elseif proxy_codec == "h264_videotoolbox" then
        -- VideoToolbox has no -crf/-preset either; -q:v (1-100, higher=better)
        -- is its quality knob.
        codec_args = {
            "-c:v h264_videotoolbox",
            "-q:v 65",
            "-pix_fmt yuv420p",
            "-c:a aac",
            "-b:a 128k",
            "-movflags +faststart",
        }
    elseif proxy_format == "webm" then
        codec_args = {
            "-c:v " .. (proxy_codec or "libvpx-vp9"),
            "-crf 31",
            "-b:v 0",
            "-row-mt 1",        -- row-based multithreading (big win on multicore)
            "-deadline good",   -- 'realtime' is even faster if you need it
            "-cpu-used 5",      -- 0=slowest/best ... 8=fastest; 5 is a good proxy tradeoff
            "-pix_fmt yuv420p", -- 8-bit 4:2:0 for broad proxy playability
            "-c:a libopus",
            "-b:a 128k",
        }
    else
        codec_args = {
            "-c:v " .. (proxy_codec or "libx264"),
            "-preset medium",
            "-crf 23",
            "-pix_fmt yuv420p",  -- 8-bit 4:2:0 so 10-bit/4:2:2 sources (e.g. MXF) stay playable
            "-c:a aac",
            "-b:a 128k",
            "-movflags +faststart",
        }
    end
    if start_timecode then
        table.insert(codec_args, 1, "-timecode " .. rio_utils.shell_quote(start_timecode))
    end
    return codec_args
end

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
---@return table|nil metadata  { format, duration_seconds, file_size_bytes, width, height, proxy_codec, audio_codec, frame_rate, pixel_format, field_order, operational_pattern, start_timecode, umid }, or nil on failure
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
        -- include the raw output inline since callers only log err, not the debug line above
        -- (which requires DEBUG level enabled) -- decode failures are otherwise unreadable in prod
        return nil, "Failed to decode ffprobe output: " .. tostring(decode_err) .. "\nraw output: " .. tostring(output)
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
        -- distinguishes OP1a (self-contained) from OP-Atom (split essence).
        operational_pattern = tags.operational_pattern_ul,
        start_timecode = tags.timecode,
        umid = tags.material_package_umid,
    }
end

--- Build and run the ffmpeg proxy command for a resolved video path plus any
--- extra audio-only inputs (already known -- no ffprobe classification here).
--- Shared by make_video_proxy (single file, no extra audio) and
--- make_op_atom_video_proxy (video path + audio paths already separated).
--- Codec selection lives entirely with the caller (opts.codec_args) rather than
--- in this packaged lib, since hardware/codec support shifts faster than this
--- file's build/release cycle -- see examples/*.lua for how it's built.
---@param input_path string  source video
---@param extra_audio string[]  additional mono/stereo audio-only inputs to merge in
---@param output_path string  proxy destination (.mp4, .webm, or .m3u8)
---@param opts? { deinterlace?: boolean, codec_args: string[] }
---@return table|nil metadata  the proxy's video metadata, or nil on failure
---@return string? err
local function run_proxy_command(input_path, extra_audio, output_path, opts)
    opts = opts or {}
    if not opts.codec_args then
        return nil, "run_proxy_command requires opts.codec_args (the -c:v/-c:a/etc argument list for the chosen proxy codec/container -- see examples/*.lua)"
    end

    -- Deinterlace (yadif) interlaced sources so the progressive proxy has no combing.
    local scale = "scale='min(1280,iw)':-2"
    local video_filter = opts.deinterlace and ("yadif," .. scale) or scale

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

    for _, arg in ipairs(opts.codec_args) do
        parts[#parts + 1] = arg
    end
    parts[#parts + 1] = rio_utils.shell_quote(output_path)

    local cmd = rio_utils.join_command(parts)

    if not rio_utils.run_quiet_command(cmd) then
        return nil, "ffmpeg proxy command failed\nCommand: " .. cmd
    else
        rio:log_info("Proxy command succeeded: " .. tostring(cmd))
    end

    -- run_quiet_command's exit-status check is known-unreliable on the real
    -- host (see rio_utils.run_command), and even a genuinely-zero encoder
    -- failure (e.g. NVENC rejecting the driver) can still leave ffmpeg's mp4
    -- muxer having finalized a valid-but-empty container. ffprobe parses that
    -- fine, so a video-less metadata table is the only reliable signal that
    -- the proxy is actually unusable.
    local metadata, meta_err = get_video_metadata(output_path)
    if not metadata then
        return nil, "ffmpeg proxy produced no readable output\n" .. tostring(meta_err) .. "\nCommand: " .. cmd
    end
    if not metadata.video_codec or not (metadata.duration_seconds and metadata.duration_seconds > 0) then
        return nil, "ffmpeg proxy has no video stream or zero duration (encoder likely failed silently)\nCommand: " .. cmd
    end
    return metadata
end

--- Transcode a single self-contained video file to a proxy (normal mp4/mov/mxf
--- OP1a case -- caller already knows this isn't a split-essence source).
---@param input_path string  source video
---@param output_path string  proxy destination (.mp4, .webm, or .m3u8)
---@param opts? { deinterlace?: boolean, codec_args: string[] }
---@return table|nil metadata  the proxy's video metadata, or nil on failure
---@return string? err
local function make_video_proxy(input_path, output_path, opts)
    return run_proxy_command(input_path, {}, output_path, opts)
end

--- Interrogate an array of related OP-Atom essence file paths by probing each
--- with ffprobe: the one path carrying a video stream is the video essence,
--- and any audio-only paths (its paired mono/stereo audio essence) are
--- collected separately. Rio hands over the full related-file set directly,
--- so no directory scanning or UMID-based filename derivation is needed.
--- A path that fails to probe (corrupt essence, unrelated sidecar file, etc.)
--- is logged and skipped rather than aborting the whole package -- only the
--- absence of any video essence at all is a hard failure.
--- Uses rio_utils.to_array to read paths: in production this can arrive as a
--- java.util.List bridged into Lua as userdata, which supports neither
--- ipairs (fails the "is this a real table" check) nor # (no metamethod at
--- all) -- only its Java methods (:size()/:get(i)) work.
---@param paths string[]  array of related essence paths for one OP-Atom package
---@return string|nil video_path  the path with a video stream
---@return string[] audio_paths  audio-only paths, in input order
---@return string? err
local function resolve_essence_paths(paths)
    local array, count = rio_utils.to_array(paths)
    if count == 0 then
        return nil, {}, "No input paths provided"
    end

    local video_path, audio_paths = nil, {}
    for i = 1, count do
        local path = array[i]
        local meta, err = get_video_metadata(path)
        if not meta then
            if rio_utils.is_directory(path) then
                -- server may now hand back a package/bundle directory instead of flat essence
                -- paths -- list it so the real contents show up in the log for diagnosis
                local entries = rio_utils.list_directory(path)
                rio:log_warn("resolve_essence_paths: '" .. tostring(path) .. "' is a directory, not a file -- contents: " .. table.concat(entries, ", "))
            else
                rio:log_warn("resolve_essence_paths: skipping unprobeable input '" .. tostring(path) .. "': " .. tostring(err))
            end
            goto continue
        end

        if meta.width then
            if video_path then
                rio:log_warn("resolve_essence_paths: multiple video-bearing inputs; using first: " .. video_path)
            else
                video_path = path
            end
        elseif meta.audio_codec then
            audio_paths[#audio_paths + 1] = path
        else
            rio:log_warn("resolve_essence_paths: input has neither video nor audio stream: " .. path)
        end

        ::continue::
    end

    if not video_path then
        return nil, {}, "No video essence found among inputs"
    end

    return video_path, audio_paths, nil
end

--- Probe an OP-Atom package's related essence files and report metadata for
--- the video essence. Since the video essence itself carries no audio in a
--- split-essence source, audio_codec is filled in from the first paired
--- audio-only essence.
---@param paths string[]  array of related essence paths for one OP-Atom package
---@return table|nil metadata  see get_video_metadata, or nil on failure
---@return string? err
local function get_op_atom_video_metadata(paths)
    local video_path, audio_paths, resolve_err = resolve_essence_paths(paths)
    if not video_path then
        return nil, resolve_err
    end

    local metadata, meta_err = get_video_metadata(video_path)
    if metadata and not metadata.audio_codec and #audio_paths > 0 then
        local audio_meta = get_video_metadata(audio_paths[1])
        if audio_meta then
            metadata.audio_codec = audio_meta.audio_codec
        end
    end

    return metadata, meta_err
end

--- Transcode an OP-Atom package (video essence + separate mono/stereo audio
--- essence files) to a proxy. paths is classified via resolve_essence_paths,
--- then the audio-only essence is merged to stereo via filter_complex.
---@param paths string[]  array of related essence paths for one OP-Atom package
---@param output_path string  proxy destination (.mp4, .webm, or .m3u8)
---@param opts? { deinterlace?: boolean, codec_args: string[] }
---@return table|nil metadata  the proxy's video metadata, or nil on failure
---@return string? err
local function make_op_atom_video_proxy(paths, output_path, opts)
    local video_path, audio_paths, resolve_err = resolve_essence_paths(paths)
    if not video_path then
        return nil, resolve_err
    end

    return run_proxy_command(video_path, audio_paths, output_path, opts)
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
    local limit = max_tags or 20
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
---@field get_video_metadata fun(video_path: string): table|nil, string? # Probe a single video file for format/duration/codecs/dimensions.
---@field make_video_proxy fun(input_path: string, output_path: string, opts?: table): table|nil, string? # Transcode a single self-contained video file to an mp4, webm, or m3u8 proxy.
---@field get_op_atom_video_metadata fun(paths: string[]): table|nil, string? # Probe an OP-Atom package's related essence files for the video essence's metadata (audio_codec backfilled from paired audio).
---@field make_op_atom_video_proxy fun(paths: string[], output_path: string, opts?: table): table|nil, string? # Transcode an OP-Atom package (video essence + separate audio essence files) to a proxy.
---@field resolve_essence_paths fun(paths: string[]): string|nil, string[], string? # Classify an OP-Atom package's essence paths into a video path and audio-only paths.
---@field make_video_thumbnail fun(input_path: string, output_path: string, time_offset?: string|number): table|nil, string? # Single-frame video thumbnail.
---@field extract_video_sample_frames fun(input_path: string, output_stem?: string, opts?: table): table[]|nil, string? # Evenly-spaced sample frames.
---@field aggregate_frame_results fun(frame_results: table[], max_tags?: number): table # Combine per-frame AI results into one metadata map.
---@field make_video_sidecar fun(input_path: string, output_path: string, duration_seconds?: number): boolean|nil, string? # Create a 7x7 sprite sheet of frames from a video.
---@field make_options_object fun(opts?: table): table # Create a defaulted options object for ffmpeg_pipeline functions.
---@field build_proxy_codec_args fun(proxy_format: string, proxy_codec: string, start_timecode?: string): string[] # Build -c:v/-c:a/etc args for libx264, h264_nvenc, h264_videotoolbox, or libvpx-vp9. Callers may shadow/wrap this for other codecs without a lib rebuild.
return {
    get_video_metadata = get_video_metadata,
    make_video_proxy = make_video_proxy,
    get_op_atom_video_metadata = get_op_atom_video_metadata,
    make_op_atom_video_proxy = make_op_atom_video_proxy,
    resolve_essence_paths = resolve_essence_paths,
    make_video_thumbnail = make_video_thumbnail,
    extract_video_sample_frames = extract_video_sample_frames,
    aggregate_frame_results = aggregate_frame_results,
    make_video_sidecar = make_video_sidecar,
    make_options_object = make_options_object,
    build_proxy_codec_args = build_proxy_codec_args,
}
