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
        do_moderation = config.do_aws_moderation
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
---@param opts? { do_labels?: boolean, do_celebrities?: boolean, do_faces?: boolean, do_text?: boolean, do_moderation?: boolean, prefix?: string }
---@return table|nil metadata  aggregated { tags, description, celebrities, detected_text, moderation_labels }, or nil
---@return string? err
local function describe_image(image_path, s3_bucket, opts)
    opts = opts or { do_labels = true, do_celebrities = true, do_faces = true, do_text = false, do_moderation = false, confidence = 80 }

    local key = (opts.prefix or "tmp/") .. (image_path:match("([^/\\]+)$") or image_path)

    local upload_ok = rio_utils.run_quiet_command(
        "aws s3 cp " .. rio_utils.shell_quote(image_path) .. " " .. rio_utils.shell_quote("s3://" .. s3_bucket .. "/" .. key)
    )
    if not upload_ok then
        return nil, "failed to upload frame to S3: " .. image_path
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

---@class AwsPipeline
---@field describe_image fun(image_path: string, s3_bucket: string, opts?: table): table|nil, string? # Analyze an image with Rekognition; returns aggregated metadata.
---@field describe_frames fun(frames: table[], s3_bucket: string, opts?: table): table[], string? # Analyze a list of frame records.

return {
    describe_image = describe_image,
    describe_frames = describe_frames,
    make_options_object = make_options_object,
}
