--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for Ollama model interaction in Rio plugin scripts
    REQUIRES: [Ollama](https://ollama.com) API available
]]--

local lua_fetch = require("lua_fetch")
local json = require("dkjson")
local rio_utils = require("rio_utils")

local b64 = require("base64")

local PROMPT = [[
Analyze this image and return a JSON object with exactly these two fields:
    "tags": an array of up to 15 short descriptive keyword tags
    "description": a single sentence describing the image
Focus on subjects, objects, colors, mood, style, and setting.
Return ONLY valid JSON - no markdown fences, no explanation.
]]

-- Ollama running locally can transiently 500 ("connection refused", "model
-- runner has unexpectedly stopped") under concurrent load from multiple
-- LuaWorkers hitting the same model runner -- worth a few retries before
-- giving up on what's otherwise a healthy server.
local MAX_RETRIES = 3
local RETRY_DELAY_SECONDS = 5

local function make_options_object(config)
    return {
        url = config.ollama_url,
        model = config.ollama_model,
        max_tags_per_frame = config.max_tags_per_frame,
    }
end

--- Cheaply confirm the Ollama server is reachable, without loading a model
--- (unlike /api/generate). Use this to fail fast with a clear message instead
--- of burning through describe_image's per-frame retries when the server is
--- fully down.
---@param opts? { url?: string }
---@return boolean is_up
---@return string? err  reason it's not reachable (status code or transport error)
local function is_server_available(opts)
    opts = opts or {}
    local url = (opts.url or "http://localhost:11434") .. "/api/tags"

    local ok, resp = pcall(function() return lua_fetch.fetch(url, { method = "GET" }) end)
    if not ok then
        return false, "Ollama request failed: " .. tostring(resp)
    end
    if resp.status ~= 200 then
        return false, "Ollama returned code: " .. tostring(resp.status) .. "\n" .. tostring(resp.body)
    end
    return true
end

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

local function describe_image(image_path, opts)
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
        model = opts.model,
        prompt = PROMPT,
        stream = false,
        images = { image_data }
    })

    local resp
    for attempt = 1, MAX_RETRIES do
        resp = lua_fetch.fetch("http://localhost:11434/api/generate", {
            method = "POST",
            body = body,
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body)
            }
        })

        rio:log_info("Ollama response code: " .. tostring(resp.status))
        rio:log_info("Ollama response body: " .. tostring(resp.body))

        if resp.status == 200 then
            break
        elseif attempt < MAX_RETRIES then
            rio:log_warn("Ollama request failed (attempt " .. attempt .. "/" .. MAX_RETRIES .. "), code: "
                .. tostring(resp.status) .. " " .. tostring(resp.body) .. " -- retrying in "
                .. RETRY_DELAY_SECONDS .. "s")
            rio_utils.sleep_seconds(RETRY_DELAY_SECONDS)
        end
    end

    if resp.status ~= 200 then
        return nil, "HTTP request failed with code: " .. tostring(resp.status) .. "\n" .. resp.body
    end

    local response_json, _, decode_err = json.decode(resp.body)
    if not response_json then
        return nil, "Failed to decode response: " .. tostring(decode_err) .. "\n" .. resp.body
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


local function describe_frames(frames, opts)
    local up, up_err = is_server_available(opts)
    if not up then
        return {}, "Ollama server unavailable: " .. tostring(up_err)
    end

    local results = {}
    for i, frame in ipairs(frames) do
        local frame_path = type(frame) == "table" and frame.path or frame
        local description, err = describe_image(frame_path, opts)
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
    describe_frames = describe_frames,
    make_options_object = make_options_object,
    is_server_available = is_server_available,
}
