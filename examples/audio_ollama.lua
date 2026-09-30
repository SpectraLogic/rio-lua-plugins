--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--

local json = require("dkjson")

plugin = {}

function plugin.schema()
  return json.encode({
      -- Ollama analysis
      { key = "ollama_url",                 type = "string",  default = "http://localhost:11434",      label = "Ollama URL" },
      { key = "ollama_model",               type = "string",  default = "llava",                       label = "Ollama Model" },
      { key = "do_ollama_summary",          type = "boolean", default = true,                          label = "Generate AI Summary (Ollama)" },
      { key = "ollama_summary_model",       type = "string",  default = "llava",                       label = "Ollama Summary Model" },
      -- Proxy / thumbnail
      { key = "proxy_quality", type = "enum", default = "speech (64k mono)", choices = {"speech (64k mono)", "music (128k stereo)"}, label = "Audio Proxy Quality" },
      { key = "thumbnail_format", type = "enum",   default = "jpg",     choices ={"jpg", "webp", "png"},             label = "Thumbnail Format" },
      { key = "thumbnail_size", type = "enum",    default = "320x180", choices ={"320x180", "640x360", "1280x720"}, label = "Thumbnail Size" },
      { key = "thumbnail_dpi",  type = "integer", default = 72,                                        label = "Thumbnail DPI" },
      -- Whisper transcription
      { key = "do_transcription",  type = "boolean", default = true,                                   label = "Enable Transcription" },
      { key = "model",    type = "string",    default = "C:\\Whisper\\models\\ggml-base.en.bin",       label = "Whisper Model Path" },
      { key = "language", type = "string",    default = "en",                                          label = "Whisper Language" },
      { key = "threads",  type = "integer",   default = 4,                                             label = "Whisper Threads" },
  })
end

-- override to support other codecs or change parameters from ffmpeg_pipeline's implementation
local build_audio_proxy_codec_args = require("audio_pipeline").build_audio_proxy_codec_args

function plugin.execute()
    ---@type RioUtils
    local rio_utils = require("rio_utils")
    ---@type AudioPipeline
    local audio_pipeline = require("audio_pipeline")
    ---@type OllamaPipeline
    local ollama = require("ollama_pipeline")
    ---@type WhisperPipeline
    local whisper = require("whisper_pipeline")

    local ollama_opts = ollama.make_options_object(settings)
    local audio_opts = audio_pipeline.make_options_object(settings)
    local whisper_opts = whisper.make_options_object(settings)

    local proxy_path = rio_utils.create_proxy_name(input, 'm4a', working_directory)
    local thumbnail_path = rio_utils.create_thumbnail_name(input, settings.thumbnail_format, working_directory)
    local sidecar_path = rio_utils.create_sidecar_name(input, settings.thumbnail_format, working_directory)
    local wav_path = rio_utils.create_wav_filename(input, working_directory)
    rio:log_info("Processing audio: " .. 
        tostring(input) .. " output: " ..
        tostring(proxy_path) .. " thumbnail: " ..
        tostring(thumbnail_path) .. " sprite: " ..
        tostring(sidecar_path) .. " wav: " ..
        tostring(wav_path) .. " working_directory: " ..
        tostring(working_directory))

    -- set statuses to "INITIALIZING" for all products
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("initializing"), nil)
    rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("initializing"), nil)
    if (whisper_opts.do_transcription) then
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("initializing"), nil)
    end
    if (ollama_opts.do_summary) then
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("initializing"), nil)
    end

    local technical_metadata, tech_err = audio_pipeline.get_audio_metadata(input)
    if not technical_metadata then
        rio:log_error("Failed to get technical metadata:" .. tostring(tech_err))
    end

    local duration = 0
    -- default type (m4a) and codec (aac) 
    audio_opts.codec_args = build_audio_proxy_codec_args(nil, nil)
    rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("active"), nil)
    local proxy_meta, proxy_err = audio_pipeline.make_audio_proxy(input, proxy_path, audio_opts)
    if not proxy_meta then
        rio:log_error("Failed to create proxy:" .. tostring(proxy_err))
        rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("failure"), tostring(proxy_err))
        -- the rest of the pipline depends on the proxy. B'bye...
        rio:save_status(rio_utils.get_status_name("failure"), tostring(proxy_err))
        return
    else
        rio:log_info("Created proxy: " .. tostring(proxy_path))
        duration = proxy_meta.duration_seconds or 0
        rio:register_proxy(proxy_path)
        rio:product_status(rio_utils.get_product_name("proxy"), rio_utils.get_status_name("completed"), nil)
    end

    rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("active"), nil)
    local sprite_success, sprite_err = audio_pipeline.make_audio_sidecar(proxy_path, sidecar_path, audio_opts)
    if not sprite_success then
        rio:log_error("Failed to create sidecar:" .. tostring(sprite_err))
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("failure"), tostring(sprite_err))
    else
        rio:log_info("Created audio sidecar: " .. tostring(sidecar_path))
        rio:register_sidecar(sidecar_path)
        rio:product_status(rio_utils.get_product_name("sidecar"), rio_utils.get_status_name("completed"), nil)
    end

    rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("active"), nil)
    local thumbnail_meta, thumbnail_err = audio_pipeline.make_waveform_thumbnail(proxy_path, thumbnail_path, audio_opts)
    if not thumbnail_meta then
        rio:log_error("Failed to create thumbnail:" .. tostring(thumbnail_err))
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("failure"), tostring(thumbnail_err))
    else
        rio:register_thumbnail(thumbnail_path)
        rio:product_status(rio_utils.get_product_name("thumbnail"), rio_utils.get_status_name("completed"), nil)
        rio:log_info("Created thumbnail: " .. tostring(thumbnail_path))
    end

    -- coalesce and save all technical metadata
    local all_technical_metadata = {}
    rio_utils.merge_as_strings(all_technical_metadata, technical_metadata)
    if proxy_meta then
        rio_utils.merge_as_strings(all_technical_metadata, proxy_meta, "proxy_")
    end
    if thumbnail_meta then
        rio_utils.merge_as_strings(all_technical_metadata, thumbnail_meta, "thumbnail_")
    end
    rio:log_debug("All metadata: " .. json.encode(all_technical_metadata, { indent = true }))
    rio:save_technical_metadata(all_technical_metadata)

    local transcription_result
    if (whisper_opts.do_transcription) then
        -- transcribe audio from the video proxy
        rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("active"), nil)
        rio:log_debug("Transcribing audio from proxy: " .. tostring(proxy_path) .. " to wav: " .. tostring(wav_path))
        local transcription_err
        transcription_result, transcription_err = whisper.transcribe_audio(proxy_path, wav_path, whisper_opts)
        if not transcription_result then
            rio:log_error("Failed to transcribe audio:" .. tostring(transcription_err))
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("failure"), tostring(transcription_err))
        else
            rio:save_transcription(transcription_result.text)
            rio:product_status(rio_utils.get_product_name("transcription"), rio_utils.get_status_name("completed"), nil)
            rio:log_debug("Transcription result: " .. transcription_result.text)
        end
    end

    if ollama_opts.do_summary then
        rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("active"), nil)
        local summary, summary_err = ollama.summarize_clip(
            transcription_result and transcription_result.text,
            nil,
            ollama_opts
        )
        if summary then
            rio:log_info("Generated Ollama summary")
            rio:save_summary(summary)
            rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("completed"), nil)
        else
            rio:log_warn("Failed to generate Ollama summary: " .. tostring(summary_err))
            rio:product_status(rio_utils.get_product_name("ai"), rio_utils.get_status_name("failure"), tostring(summary_err))
        end
    end

    rio:save_status(rio_utils.get_status_name("completed"), nil)
end
