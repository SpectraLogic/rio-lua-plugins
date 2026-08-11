--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
    helper functions for whisper.cpp (whisper-cli) speech-to-text in Rio plugin scripts
    REQUIRES: whisper-cli (whisper.cpp) installed and available in the system PATH.
    REQUIRES: ffmpeg (to normalize audio to the 16 kHz mono WAV whisper.cpp requires).
    REQUIRES: a whisper model file; pass opts.model.
]]--

---@type RioUtils
local rio_utils = require("rio_utils")

local WHISPER = "whisper-cli"
local FFMPEG = "ffmpeg"

--- Extract whisper options from a settings object
--- @param config table  settings object with Whisper options
--- @return table  Whisper options table with keys: model_path, language, threads
local function make_options_object(config)
    return {
        model = config.model,
        language = config.language,
        threads = config.threads,
    }
end

--- Normalize any audio/video input to the 16 kHz mono WAV that whisper.cpp requires.
---@param input_path string  source media (audio or video)
---@param wav_path string  destination .wav path
---@return boolean ok
---@return string? err
local function extract_audio_wav(input_path, wav_path)
    local cmd = rio_utils.join_command({
        FFMPEG, "-y",
        "-i " .. rio_utils.shell_quote(input_path),
        "-vn",              -- ignore any video stream
        "-ac 1",            -- mono
        "-ar 16000",        -- 16 kHz
        "-c:a pcm_s16le",   -- 16-bit PCM WAV
        rio_utils.shell_quote(wav_path),
    })
    if not rio_utils.run_quiet_command(cmd) then
        return false, "ffmpeg audio extraction failed"
    end
    return true
end

--- Transcribe an audio/video file to plain text with whisper-cli.
--- Converts the input to 16 kHz mono WAV, runs whisper-cli with -otxt, then reads
--- the resulting .txt file (the clean, timestamp-free transcript).
---@param input_path string  source media file
---@param output_path string  directory prefix for intermediate + output files (e.g. the temp cache)
---@param opts? { model: string, language?: string, threads?: number }
---@return table|nil result  { text, txt_path, word_count, char_count }, or nil on failure
---@return string? err
local function transcribe_audio(input_path, output_path, opts)
    opts = opts or {}
    local model = opts.model
    if not model or model == "" then
        return nil, "no whisper model configured (set opts.model)"
    end

    local stem = rio_utils.sanitize_filename(rio_utils.split_file_name(input_path))
    local wav_path = output_path .. stem .. ".wav"
    local out_base = output_path .. stem       -- whisper-cli appends the .txt extension
    local txt_path = out_base .. ".txt"

    -- 1. whisper.cpp only accepts 16 kHz mono WAV -- normalize first.
    local ok, err = extract_audio_wav(input_path, wav_path)
    if not ok then
        return nil, err
    end

    -- 2. transcribe to a plain-text sidecar (-otxt writes <out_base>.txt).
    local parts = {
        WHISPER,
        "-m " .. rio_utils.shell_quote(model),
        "-f " .. rio_utils.shell_quote(wav_path),
        "-otxt",
        "-of " .. rio_utils.shell_quote(out_base),
    }
    if opts.language then parts[#parts + 1] = "-l " .. rio_utils.shell_quote(opts.language) end
    if opts.threads then parts[#parts + 1] = "-t " .. tostring(opts.threads) end

    if not rio_utils.run_quiet_command(rio_utils.join_command(parts)) then
        return nil, "whisper-cli failed"
    end

    -- 3. read the clean transcript back.
    local f = io.open(txt_path, "r")
    if not f then
        return nil, "transcript file not produced: " .. txt_path
    end
    local text = rio_utils.trim(f:read("*a") or "")
    f:close()

    local word_count = 0
    for _ in text:gmatch("%S+") do word_count = word_count + 1 end

    return {
        text = text,
        txt_path = txt_path,
        word_count = word_count,
        char_count = #text,
    }
end

---@class WhisperPipeline
---@field extract_audio_wav fun(input_path: string, wav_path: string): boolean, string? # Normalize media to 16 kHz mono WAV.
---@field transcribe_audio fun(input_path: string, output_path: string, opts?: table): table|nil, string? # Transcribe media to plain text via whisper-cli.

return {
    extract_audio_wav = extract_audio_wav,
    transcribe_audio = transcribe_audio,
    make_options_object = make_options_object,
}
