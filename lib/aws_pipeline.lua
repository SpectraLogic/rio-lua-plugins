--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for AWS Rekognition in Rio plugin scripts
    REQUIRES: aws-cli v2, credentials, and a scratch S3 bucket available
]]--

---@type RioUtils
local rio_utils = require("rio_utils")
local json = require("dkjson")
local lua_fetch = require("lua_fetch")

local FFMPEG = "ffmpeg"

--- Extract AWS options from a settings object
--- @param config table  settings object with AWS options
--- @return table  AWS options table with keys: s3_bucket, confidence, do_labels, do_celebrities, do_faces, do_text, do_moderation
local function make_options_object(config)
    return {
        s3_bucket = config.s3_bucket,
        confidence = tonumber(config.aws_confidence_threshold) or 80,
        do_labels = config.do_aws_labels,
        do_celebrities = config.do_aws_celebrities,
        do_faces = config.do_aws_faces,
        do_text = config.do_aws_text,
        do_moderation = config.do_aws_moderation,
        profile = config.aws_profile,
        language = config.language,
        max_timeout_seconds = config.max_timeout_seconds,
    }
end


--- Upload a local file to S3, call one Rekognition operation, return parsed JSON.
---@param s3_key string  full S3 key (bucket-relative)
---@param s3_bucket string  S3 bucket name
---@param operation string  rekognition sub-command, e.g. "detect-labels"
---@param extra_args? string  additional CLI flags
---@return table|nil result  decoded JSON response, or nil on failure
---@return string? err
local function rekognition_call(s3_key, s3_bucket, operation, extra_args)
    local image_arg = "--image " .. rio_utils.shell_quote(
        '{"S3Object":{"Bucket":"' .. s3_bucket .. '","Name":"' .. s3_key .. '"}}'
    )
    local cmd = rio_utils.join_command({
        "aws rekognition", operation, image_arg, extra_args
    })
    local output = rio_utils.run_command(cmd)
    if not output then
        return nil, "aws rekognition " .. operation .. " command failed"
    end
    local result, _, decode_err = json.decode(output)
    if not result then
        return nil, "failed to decode rekognition response: " .. tostring(decode_err)
    end
    return result
end

--- Analyze a single image with the requested Rekognition operations.
--- Uploads to S3, runs each enabled operation, cleans up, returns aggregated metadata.
---@param image_path string  local path to the image file
---@param s3_bucket string  S3 bucket name to use for temporary upload
---@param opts? { do_labels?: boolean, do_celebrities?: boolean, do_faces?: boolean, do_text?: boolean, do_moderation?: boolean, prefix?: string, profile?: string }
---@return table|nil metadata  aggregated { tags, description, celebrities, detected_text, moderation_labels }, or nil
---@return string? err
local function describe_image(image_path, s3_bucket, opts)
    opts = opts or { do_labels = true, do_celebrities = true, do_faces = true, do_text = false, do_moderation = false, confidence = 80 }

    local key = (opts.prefix or "tmp/") .. (image_path:match("([^/\\]+)$") or image_path)

    local upload_cmd = "aws s3 cp " .. rio_utils.shell_quote(image_path) .. " " .. rio_utils.shell_quote("s3://" .. s3_bucket .. "/" .. key)
    if opts.profile then
        upload_cmd = upload_cmd .. " --profile " .. rio_utils.shell_quote(opts.profile)
    end
    local upload_ok, upload_output = rio_utils.run_quiet_command(upload_cmd)
    -- The close-status can report success even when the aws CLI actually
    -- failed (see rio_utils.run_quiet_command), so also check its output
    -- for the CLI's own "An error occurred (...)" failure marker.
    local aws_err = upload_output and upload_output:match("(An error occurred[^\n]*)")
    if not upload_ok or aws_err then
        return nil, "failed to upload frame to S3: " .. (aws_err or upload_output or upload_cmd)
    else
        rio:log_debug("Uploaded frame to S3: " .. upload_cmd)
    end



    local metadata = { tags = {}, celebrities = {} }
    local errors = {}

    if opts.do_labels then
        local result, err = rekognition_call(key, s3_bucket, "detect-labels", "--max-labels 15")
        if result and result.Labels then
            for _, label in ipairs(result.Labels) do
                if label.Confidence and label.Confidence >= (opts.confidence) then
                    metadata.tags[#metadata.tags + 1] = label.Name:lower()
                end
            end
            if #metadata.tags > 0 and not metadata.description then
                metadata.description = "Scene contains: " .. table.concat(metadata.tags, ", ", 1, math.min(5, #metadata.tags))
            end
        else
            errors[#errors + 1] = err or "detect-labels returned no Labels"
        end
    end

    if opts.do_celebrities then
        local result, err = rekognition_call(key, s3_bucket, "recognize-celebrities")
        if result and result.CelebrityFaces then
            for _, celeb in ipairs(result.CelebrityFaces) do
                if celeb.MatchConfidence and celeb.MatchConfidence >= (opts.confidence) then
                    metadata.celebrities[#metadata.celebrities + 1] = celeb.Name
                    metadata.tags[#metadata.tags + 1] = celeb.Name:lower()
                end
            end
        else
            errors[#errors + 1] = err or "recognize-celebrities returned no CelebrityFaces"
        end
    end

    if opts.do_faces then
        local result, err = rekognition_call(key, s3_bucket, "detect-faces", "--attributes ALL")
        if result and result.FaceDetails then
            metadata.face_count = #result.FaceDetails
        else
            errors[#errors + 1] = err or "detect-faces returned no FaceDetails"
        end
    end

    if opts.do_text then
        local result, err = rekognition_call(key, s3_bucket, "detect-text")
        if result and result.TextDetections then
            local lines = {}
            for _, detection in ipairs(result.TextDetections) do
                if detection.Type == "LINE" and detection.Confidence and (detection.Confidence >= opts.confidence) then
                    lines[#lines + 1] = detection.DetectedText
                end
            end
            metadata.detected_text = table.concat(lines, " | ")
        else
            errors[#errors + 1] = err or "detect-text returned no TextDetections"
        end
    end

    if opts.do_moderation then
        local result, err = rekognition_call(key, s3_bucket, "detect-moderation-labels")
        if result and result.ModerationLabels then
            local flags = {}
            for _, label in ipairs(result.ModerationLabels) do
                flags[#flags + 1] = label.Name
            end
            metadata.moderation_labels = table.concat(flags, ", ")
        else
            errors[#errors + 1] = err or "detect-moderation-labels returned no ModerationLabels"
        end
    end

    rio_utils.run_quiet_command(
        "aws s3 rm " .. rio_utils.shell_quote("s3://" .. s3_bucket .. "/" .. key)
    )

    if #errors > 0 then
        rio:log_warn("aws_pipeline.describe_image partial errors: " .. table.concat(errors, "; "))
    end

    return metadata
end

--- Analyze a list of frame records (from extract_video_sample_frames).
---@param frames table[]  list of { path, frame_index, timestamp_label, timestamp_seconds }
---@param s3_bucket string  S3 bucket name to use for temporary upload
---@param opts? table  passed through to describe_image
---@return table[] results  per-frame metadata tables
---@return string? err  first fatal error, if any
local function describe_frames(frames, s3_bucket, opts)
    local results = {}
    for _, frame in ipairs(frames) do
        local frame_path = (type(frame) == "table" and frame.path or frame) --[[@as string]]
        local description, err = describe_image(frame_path, s3_bucket, opts)
        if not description then
            return results, "failed to describe frame " .. tostring(frame_path) .. ": " .. tostring(err)
        end
        if type(frame) == "table" then
            description.frame_path = frame.path
            description.frame_index = frame.frame_index
            description.frame_timecode = frame.timestamp_label
            description.frame_timestamp_seconds = frame.timestamp_seconds
        end
        results[#results + 1] = description
    end
    return results
end

--- Normalize any audio/video input to the 16 kHz MP3 format forAWS Transcription
---@param input_path string  source media (audio or video)
---@param mp3_path string  destination .mp3 path
---@return boolean ok
---@return string? err
local function extract_audio_mp3(input_path, mp3_path)
    local cmd = rio_utils.join_command({
        FFMPEG, "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-vn",              -- ignore any video stream
        "-ac 1",            -- mono
        "-ar 16000",        -- 16 kHz
        "-b:a 64k",         -- 64 kbps MP3
        rio_utils.shell_quote(mp3_path),
    })
    rio:log_info("Running ffmpeg command: " .. tostring(cmd))
    if not rio_utils.run_quiet_command(cmd) then
        return false, "ffmpeg audio extraction failed"
    else  
        rio:log_info("Extracted audio to MP3: " .. tostring(mp3_path))
    end
    return true
end


--- Extract audio from a media file, upload it to S3, run it through AWS
--- Transcribe, poll until the job finishes, and download the resulting
--- transcript text.
---@param proxy_path string  source media file -- generally the proxy
---@param mp3_path string  destination path for the normalized 16 kHz mono MP3 (build with a helper like rio_utils.create_wav_filename)
---@param s3_bucket string  S3 bucket name to use for temporary upload
---@param opts? { language_code?: string, media_format?: string, prefix?: string, profile?: string, poll_interval_seconds?: number, max_wait_seconds?: number }
---@return table|nil result  { text, word_count, char_count, job_name }, or nil on failure
---@return string? err
local function transcribe_audio(proxy_path, mp3_path, s3_bucket, opts)
    opts = opts or {}
    rio:log_info("transcribe_audio: proxy_path=" .. tostring(proxy_path) .. ", mp3_path=" .. tostring(mp3_path) .. ", " ..
    "s3_bucket=" .. tostring(s3_bucket) .. ", opts=" .. json.encode(opts, { indent = true }))
 
    -- 16 kHz mono MP3
    local ok, err = extract_audio_mp3(proxy_path, mp3_path)
    if not ok then
        return nil, err
    end

    local profile_flag = opts.profile and (" --profile " .. rio_utils.shell_quote(opts.profile)) or ""

    local key = (opts.prefix or "tmp/") .. (mp3_path:match("([^/\\]+)$") or mp3_path)
    local s3_uri = "s3://" .. s3_bucket .. "/" .. key

    local upload_cmd = "aws s3 cp " .. rio_utils.shell_quote(mp3_path) .. " " .. rio_utils.shell_quote(s3_uri) .. profile_flag
    local upload_ok, upload_output = rio_utils.run_quiet_command(upload_cmd)
    -- The close-status can report success even when the aws CLI actually
    -- failed (see rio_utils.run_quiet_command), so also check its output
    -- for the CLI's own "An error occurred (...)" failure marker.
    local upload_err = upload_output and upload_output:match("(An error occurred[^\n]*)")
    if not upload_ok or upload_err then
        return nil, "failed to upload audio to S3: " .. (upload_err or upload_output or upload_cmd)
    else
        rio:log_debug("Uploaded audio to S3: " .. upload_cmd)
    end

    -- Job names are unique per account; a timestamp keeps repeat runs on the
    -- same file from colliding with a still-registered prior job.
    local stem = rio_utils.sanitize_filename(mp3_path:match("([^/\\]+)$") or mp3_path)
    local job_name = "transcribe-" .. stem .. "-" .. string.format("%d", os.time())
    local media_format = opts.media_format or rio_utils.get_file_extension(mp3_path) or "mp3"

    local start_cmd = rio_utils.join_command({
        "aws transcribe start-transcription-job",
        "--transcription-job-name " .. rio_utils.shell_quote(job_name),
        "--media " .. rio_utils.shell_quote("MediaFileUri=" .. s3_uri),
        "--media-format " .. rio_utils.shell_quote(media_format),
        "--language-code " .. rio_utils.shell_quote(opts.language_code or "en-US"),
        opts.profile and ("--profile " .. rio_utils.shell_quote(opts.profile)) or nil,
    })
    -- run_command discards stderr (fine for parsing JSON stdout), but that
    -- also throws away the aws CLI's actual error text on failure -- use
    -- run_quiet_command + the "An error occurred" marker instead, same as
    -- the upload step above, so a real failure here is diagnosable.
    local start_ok, start_output = rio_utils.run_quiet_command(start_cmd)
    local start_err = start_output and start_output:match("(An error occurred[^\n]*)")
    if not start_ok or start_err then
        return nil, "aws transcribe start-transcription-job failed: " .. (start_err or start_output or "") .. "\nCommand: " .. start_cmd
    end

    local get_cmd = rio_utils.join_command({
        "aws transcribe get-transcription-job",
        "--transcription-job-name " .. rio_utils.shell_quote(job_name),
        opts.profile and ("--profile " .. rio_utils.shell_quote(opts.profile)) or nil,
    })

    local poll_interval = opts.poll_interval_seconds or 5
    local max_wait = opts.max_wait_seconds or 600
    local elapsed = 0
    local job
    while true do
        local get_ok, get_output = rio_utils.run_quiet_command(get_cmd)
        local get_err = get_output and get_output:match("(An error occurred[^\n]*)")
        if not get_ok or get_err then
            return nil, "aws transcribe get-transcription-job failed: " .. (get_err or get_output or "") .. "\nCommand: " .. get_cmd
        end
        local result, _, decode_err = json.decode(get_output)
        job = result and result.TranscriptionJob
        if not job then
            return nil, "failed to decode get-transcription-job response: " .. tostring(decode_err)
        end
        if job.TranscriptionJobStatus == "COMPLETED" or job.TranscriptionJobStatus == "FAILED" then
            break
        end
        if elapsed >= max_wait then
            return nil, "transcription job " .. job_name .. " did not finish within " .. max_wait .. "s"
        end
        rio_utils.sleep_seconds(poll_interval)
        elapsed = elapsed + poll_interval
    end

    -- Best-effort cleanup regardless of outcome -- neither the uploaded audio
    -- nor the job registration needs to survive past this call.
    rio_utils.run_quiet_command("aws transcribe delete-transcription-job --transcription-job-name " .. rio_utils.shell_quote(job_name) .. profile_flag)
    rio_utils.run_quiet_command("aws s3 rm " .. rio_utils.shell_quote(s3_uri) .. profile_flag)

    if job.TranscriptionJobStatus ~= "COMPLETED" then
        return nil, "transcription job " .. job_name .. " failed: " .. tostring(job.FailureReason)
    end

    local transcript_uri = job.Transcript and job.Transcript.TranscriptFileUri
    if not transcript_uri then
        return nil, "transcription job " .. job_name .. " completed but returned no TranscriptFileUri"
    end

    local resp = lua_fetch.fetch(transcript_uri)
    if not resp or resp.status ~= 200 then
        return nil, "failed to download transcript: HTTP " .. tostring(resp and resp.status)
    end

    local transcript_json, _, transcript_decode_err = json.decode(resp.body)
    local text = transcript_json
        and transcript_json.results
        and transcript_json.results.transcripts
        and transcript_json.results.transcripts[1]
        and transcript_json.results.transcripts[1].transcript
    if not text then
        return nil, "failed to decode transcript JSON: " .. tostring(transcript_decode_err)
    end
    local trimmed_text = rio_utils.trim(text)

    local word_count = 0
    for _ in trimmed_text:gmatch("%S+") do word_count = word_count + 1 end

    -- Clean up the uploaded MP3 from S3, since it's no longer needed.
    rio_utils.run_quiet_command(
        "aws s3 rm " .. rio_utils.shell_quote(s3_uri)
    )

    return {
        text = trimmed_text,
        word_count = word_count,
        char_count = #trimmed_text,
        job_name = job_name,
    }
end

---@class AwsPipeline
---@field describe_image fun(image_path: string, s3_bucket: string, opts?: table): table|nil, string? # Analyze an image with Rekognition; returns aggregated metadata.
---@field describe_frames fun(frames: table[], s3_bucket: string, opts?: table): table[], string? # Analyze a list of frame records.
---@field transcribe_audio fun(audio_path: string, s3_bucket: string, opts?: table): table|nil, string? # Upload audio, run AWS Transcribe, return { text, word_count, char_count, job_name }.

return {
    describe_image = describe_image,
    describe_frames = describe_frames,
    transcribe_audio = transcribe_audio,
    make_options_object = make_options_object,
}
