--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for Ollama model interaction in Rio plugin scripts
    REQUIRES: [Ollama](https://ollama.com) API available
]]--

local http = require("socket.http")
local b64 = require("base64")
local ltn12 = require("ltn12")
local json = require("dkjson")

local PROMPT = [[
Analyze this image and return a JSON object with exactly these two fields:
    "tags": an array of 5-15 short descriptive keyword tags
    "description": a single sentence describing the image
Focus on subjects, objects, colors, mood, style, and setting.
Return ONLY valid JSON - no markdown fences, no explanation.
]]

local function parse_model_response(response_text)
    local cleaned = response_text
        :gsub("^%s*```json%s*", "")
        :gsub("^%s*```%s*", "")
        :gsub("%s*```%s*$", "")

    local parsed, _, decode_err = json.decode(cleaned)
    if not parsed then
        return nil, "Failed to decode model response: " .. tostring(decode_err) .. "\n" .. cleaned
    end

    return parsed
end

local function process_response(response_json)
    local ret = {
        ai_description = response_json.description,
        ai_model = "ollama llava"
    }
    for i, v in ipairs(response_json.tags or {}) do
        ret["ai_tag" .. i] = v
    end
    return ret
end

local function describe_image(image_path)
    local image_file, open_err = io.open(image_path, "rb")
    if not image_file then
        return nil, "Failed to open image: " .. tostring(open_err)
    end

    local image_bytes = image_file:read("*a")
    image_file:close()

    if not image_bytes then
        return nil, "Failed to read image bytes"
    end

    local image_data = b64.encode(image_bytes)
    local body = json.encode({
        model = "llava",
        prompt = PROMPT,
        stream = false,
        images = { image_data }
    })

    local response_body = {}
    local _, code = http.request{
        url = "http://localhost:11434/api/generate",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body)
    }

    local response_str = table.concat(response_body)
    if code ~= 200 then
        return nil, "HTTP request failed with code: " .. tostring(code) .. "\n" .. response_str
    end

    local response_json, _, decode_err = json.decode(response_str)
    if not response_json then
        return nil, "Failed to decode response: " .. tostring(decode_err) .. "\n" .. response_str
    end

    if response_json.response then
        local model_json, model_err = parse_model_response(response_json.response)
        if not model_json then
            return nil, model_err
        end
        return process_response(model_json)
    end

    return process_response(response_json)
end

if ... == nil then
    local description, err = describe_image("frame.jpg")
    if not description then
        print(err)
    else
        print(json.encode(description, { indent = true }))
    end
end

local function describe_frames(frames)
    local results = {}
    for i, frame in ipairs(frames) do
        local frame_path = type(frame) == "table" and frame.path or frame
        local description, err = describe_image(frame_path)
        if not description then
            return results, "Failed to describe frame:" .. frame_path .. " " .. tostring(err)
        else
            if type(frame) == "table" then
                description.frame_path = frame.path
                description.frame_index = frame.frame_index
                description.frame_timecode = frame.timestamp_label
                description.frame_timestamp_seconds = frame.timestamp_seconds
            end
            results[i] = description
        end
    end
    return results
end

return {
    describe_image = describe_image,
    describe_frames = describe_frames
}
