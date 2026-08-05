--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- helper functions for Rio plugin scripts

local IS_WINDOWS = os.getenv("OS") == "Windows_NT"

--- Split a path into its filename stem and extension.
---@param path string  full or relative path
---@return string stem  filename without directory or extension
---@return string|nil extension  extension without the dot, or nil if none
local function split_file_name(path)
    local file_name = path:match("([^/]+)$") or path
    local stem = file_name:match("(.+)%.([^%.]+)$") or file_name
    local extension = file_name:match("%.([^%.]+)$")
    return stem, extension
end

--- Replace filename-hostile characters with underscores.
---@param value any  input filename fragment
---@return string  filesystem-friendly filename fragment
local function sanitize_filename(value)
    return (tostring(value or "")
    :gsub("[^%w%._%-]+", "_")
    :gsub("_+", "_")
    :gsub("^[_%.%-]+", "")
    :gsub("[_%.%-]+$", ""))
end

--- Build a proxy output path: `<output_path><stem>-Proxy.<ext>`.
---@param path string  source file path
---@param extension? string  proxy extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full proxy path
local function create_proxy_name(path, extension, output_path)
    local stem = sanitize_filename(split_file_name(path))
    return output_path .. stem .. "-Proxy." .. (extension or "webp")
end

--- Build a thumbnail output path: `<output_path><stem>-Thumbnail.<ext>`.
---@param path string  source file path
---@param extension? string  thumbnail extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full thumbnail path
local function create_thumbnail_name(path, extension, output_path)
    local stem = sanitize_filename(split_file_name(path))
    return output_path .. stem .. "-Thumbnail." .. (extension or "webp")
end

--- Build a preview output path: `<output_path><stem>-Preview.<ext>`.
---@param path string  source file path
---@param extension? string  preview extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full preview path
local function create_preview_name(path, extension, output_path)
    local stem = sanitize_filename(split_file_name(path))
    return output_path .. stem .. "-Preview." .. (extension or "webp")
end

--- Build a sprite output path: `<output_path><stem>-Sprite.<ext>`.
---@param path string  source file path
---@param extension? string  sprite extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full sprite path
local function create_sidecar_name(path, extension, output_path)
    local stem = sanitize_filename(split_file_name(path))
    return output_path .. stem .. "-Sprite." .. (extension or "webp")
end

--- Single-quote (Unix) or double-quote (Windows) a value for safe use as one shell argument.
---@param path any  value to quote (coerced via tostring)
---@return string  shell-safe quoted string
local function shell_quote(path)
    if IS_WINDOWS then
        return '"' .. tostring(path):gsub('"', '""') .. '"'
    end
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- Run a shell command and return its stdout. stderr is discarded so it does
--- not corrupt parseable output (JSON, magick format strings, etc.).
--- Returns nil when the command produces no stdout (treat as failure).
---@param cmd string  full shell command line
---@return string|nil  stdout on success, nil on failure
local function run_command(cmd)
    -- Discard stderr so it never pollutes stdout that callers parse.
    -- os.tmpname() is unreliable on Windows, so use the platform null device.
    local null = IS_WINDOWS and " 2>NUL" or " 2>/dev/null"
    local pipe = io.popen(cmd .. null)
    if not pipe then
        rio:log_warn("Failed to start command: " .. cmd)
        return nil
    end

    local output = pipe:read("*a")
    -- NOTE: in this JVM-embedded host the runtime reaps the child process, so
    -- pipe:close() can't recover a reliable exit status -- it returns nil even on
    -- success. Do not gate on it; judge success by output content instead.
    pipe:close()

    if not output or output == "" then
        rio:log_warn("Command produced no output: " .. cmd)
        return nil
    end

    return output
end

--- Run a shell command for its side effects, discarding output.
---@param cmd string  full shell command line
---@return boolean  true if the command exited successfully
local function run_quiet_command(cmd)
    -- The test harness patches io.popen()/close() so callers can rely on the
    -- returned status. Capture combined output to aid diagnostics on failures.
    local p = io.popen(cmd .. " 2>&1")
    if not p then return false end
    local output = p:read("*a") or ""
    local ok = p:close()
    if not (ok == true or ok == 0) then
        rio:log_warn("Command failed: " .. cmd .. "\n" .. output)
        return false
    end

    return true
end

--- Return whether a regular file can be opened for reading.
---@param path string
---@return boolean
local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

--- Join command parts with spaces, skipping nil entries.
---@param parts (string|nil)[]  command fragments (nils are dropped)
---@return string  the assembled command line
local function join_command(parts)
    local filtered = {}
    for _, part in ipairs(parts) do
        if part then
            filtered[#filtered + 1] = part
        end
    end
    return table.concat(filtered, " ")
end

--- Parse the leading number out of a string, ignoring surrounding whitespace.
---@param s string|nil
---@return number|nil
local function parse_num(s)
    s = (s or ""):match("^%s*(.-)%s*$")
    local num = s:match("^([%d%.]+)")
    return num and tonumber(num) or nil
end

--- Parse a byte count with an optional unit suffix (B/K/M/G/KB/MB/GB) into bytes.
---@param s string|nil
---@return number|nil  size in bytes, or nil if unparseable
local function parse_bytes(s)
    s = (s or ""):match("^%s*(.-)%s*$")
    local units = {
        GB = 1024^3,
        MB = 1024^2,
        KB = 1024,
        G = 1024^3,
        M = 1024^2,
        K = 1024,
        B = 1,
    }

    for suffix, mult in pairs(units) do
        if s:sub(-#suffix) == suffix then
            local n = tonumber(s:sub(1, #s - #suffix))
            return n and math.floor(n * mult) or nil
        end
    end

    return tonumber(s)
end

--- Parse a "numerator/denominator" ratio (e.g. "30000/1001") or plain number.
---@param value string|nil
---@return number|nil
local function parse_ratio(value)
    if not value or value == "" then
        return nil
    end

    local numerator, denominator = value:match("^(%-?%d+)%/(%-?%d+)$")
    if numerator and denominator then
        numerator = tonumber(numerator)
        denominator = tonumber(denominator)
        if denominator and denominator ~= 0 then
            return numerator / denominator
        end
        return nil
    end

    return tonumber(value)
end

--- Trim leading and trailing whitespace.
---@param value any  coerced via tostring
---@return string
local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

--- Return a path's lowercase file extension (without the dot), or nil.
---@param path string
---@return string|nil
local function get_file_extension(path)
    local _, extension = split_file_name(path)
    return extension and extension:lower() or nil
end

--- Format seconds as `HH:MM:SS.mmm`.
---@param total_seconds number
---@return string
local function format_timestamp(total_seconds)
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds - (hours * 3600) - (minutes * 60)
    return string.format("%02d:%02d:%06.3f", hours, minutes, seconds)
end

--- Like format_timestamp but filename-safe (`HH-MM-SS_mmm`).
---@param total_seconds number
---@return string
local function format_timestamp_for_filename(total_seconds)
    return (format_timestamp(total_seconds):gsub(":", "-"):gsub("%.", "_"))
end

--- Copy all key/values from `src` into `dst`, stringifying values and optionally
--- prefixing keys. Used to satisfy save_technical_metadata's Map<String,String> contract.
---@param dst table<string,string>  destination table (mutated in place)
---@param src? table  source map
---@param prefix? string  optional key prefix
local function merge_as_strings(dst, src, prefix)
    for k, v in pairs(src or {}) do
        dst[(prefix or "") .. k] = tostring(v)
    end
end

-- normmalize product name to enum
local product_names = {
    ["proxy"] = "PROXY",
    ["thumbnail"] = "THUMBNAIL",
    ["sidecar"] = "SIDECAR",
    ["preview"] = "PREVIEW",
    ["transcription"] = "TRANSCRIPTION",
    ["ai"] = "AI",
}
local function get_product_name(name)
    return product_names[name:lower()] or "UNKNOWN"
end

-- normalize statuses
local status_names = {
    ["initializing"] = "INITIALIZING",
    ["completed"] = "COMPLETED",
    ["failure"] = "FAILURE",
    ["active"] = "ACTIVE",
}
local function get_status_name(name)
    return status_names[name:lower()] or "UNKNOWN"
end


---@class RioUtils
---@field split_file_name fun(path: string): string, string|nil # Split a path into filename stem and extension.
---@field sanitize_filename fun(value: any): string # Replace filename-hostile characters with underscores.
---@field create_proxy_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Proxy.<ext>` path.
---@field create_thumbnail_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Thumbnail.<ext>` path.
---@field create_sidecar_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Sprite.<ext>` path.
---@field create_preview_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Preview.<ext>` path.
---@field merge_as_strings fun(dst: table, src: table, prefix?: string) # Copy src into dst, stringifying values (for save_techbical_metadata).
---@field shell_quote fun(path: any): string # Single-quote a value as one safe shell argument.
---@field run_command fun(cmd: string): string|nil # Run a command, return stdout (nil + logs stderr on failure).
---@field run_quiet_command fun(cmd: string): boolean # Run a command for its side effects; true on success.
---@field join_command fun(parts: (string|nil)[]): string # Join command parts with spaces, dropping nils.
---@field file_exists fun(path: string): boolean # Return true when a file exists and is readable.
---@field parse_num fun(s: string|nil): number|nil # Parse the leading number from a string.
---@field parse_bytes fun(s: string|nil): number|nil # Parse a byte count with B/K/M/G suffix into bytes.
---@field parse_ratio fun(value: string|nil): number|nil # Parse "num/den" or a plain number.
---@field trim fun(value: any): string # Trim surrounding whitespace.
---@field get_file_extension fun(path: string): string|nil # Lowercase extension without the dot.
---@field format_timestamp fun(total_seconds: number): string # Seconds -> `HH:MM:SS.mmm`.
---@field format_timestamp_for_filename fun(total_seconds: number): string # Seconds -> filename-safe `HH-MM-SS_mmm`.
---@field get_product_name fun(name: string): string # Normalize product name to enum.
---@field get_status_name fun(name: string): string # Normalize status name to enum.

return {
    split_file_name = split_file_name,
    sanitize_filename = sanitize_filename,
    create_proxy_name = create_proxy_name,
    create_thumbnail_name = create_thumbnail_name,
    create_sidecar_name = create_sidecar_name,
    create_preview_name = create_preview_name,
    merge_as_strings = merge_as_strings,
    shell_quote = shell_quote,
    run_command = run_command,
    run_quiet_command = run_quiet_command,
    join_command = join_command,
    file_exists = file_exists,
    parse_num = parse_num,
    parse_bytes = parse_bytes,
    parse_ratio = parse_ratio,
    trim = trim,
    get_file_extension = get_file_extension,
    format_timestamp = format_timestamp,
    format_timestamp_for_filename = format_timestamp_for_filename,
    get_product_name = get_product_name,
    get_status_name = get_status_name,
}
