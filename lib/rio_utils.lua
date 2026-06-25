--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- helper functions for Rio plugin scripts

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

--- Build a proxy output path: `<output_path><stem>-Proxy.<ext>`.
---@param path string  source file path
---@param extension? string  proxy extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full proxy path
local function create_proxy_name(path, extension, output_path)
    local stem = split_file_name(path)
    return output_path .. stem .. "-Proxy." .. (extension or "webp")
end

--- Build a thumbnail output path: `<output_path><stem>-Thumbnail.<ext>`.
---@param path string  source file path
---@param extension? string  thumbnail extension without dot (default "webp")
---@param output_path string  directory prefix for the result
---@return string  full thumbnail path
local function create_thumbnail_name(path, extension, output_path)
    local stem = split_file_name(path)
    return output_path .. stem .. "-Thumbnail." .. (extension or "webp")
end

--- Single-quote a value for safe use as one shell argument.
---@param path any  value to quote (coerced via tostring)
---@return string  shell-safe single-quoted string
local function shell_quote(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- Run a shell command and return its stdout. stderr is captured separately and
--- logged on failure; returns nil when the command produced no stdout but wrote
--- to stderr (e.g. a missing binary or bad arguments).
---@param cmd string  full shell command line
---@return string|nil  stdout on success, nil on failure
local function run_command(cmd)
    -- stderr goes to a temp file (not merged into stdout, which callers parse)
    -- so we can surface it on failure instead of returning a silent nil. The
    -- usual culprit is a missing binary: "command not found" from a PATH that
    -- lacks /opt/homebrew/bin when launched outside an interactive shell.
    local err_file = os.tmpname()
    local pipe = io.popen(cmd .. " 2>" .. err_file)
    if not pipe then
        os.remove(err_file)
        rio:log_warn("Failed to start command: " .. cmd)
        return nil
    end

    local output = pipe:read("*a")
    -- NOTE: in this JVM-embedded host the runtime reaps the child process, so
    -- pipe:close() can't recover a reliable exit status -- it returns nil even on
    -- success. So we do NOT gate on it; success is judged by output/stderr instead.
    pipe:close()

    local ef = io.open(err_file, "r")
    local stderr = ef and ef:read("*a") or ""
    if ef then ef:close() end
    os.remove(err_file)

    -- Real failure looks like: no stdout, but something on stderr.
    if (output == nil or output == "") and stderr ~= "" then
        rio:log_warn("Command failed: " .. cmd .. "\n" .. stderr)
        return nil
    end

    return output
end

--- Run a shell command for its side effects, discarding output.
---@param cmd string  full shell command line
---@return boolean  true if the command exited successfully
local function run_quiet_command(cmd)
    -- Use io.popen (proven to work in this host) rather than os.execute, which
    -- stalls here. read("*a") drains the pipe so the child can't block; close()
    -- waits for exit. Handles Lua 5.2+ (bool) and 5.1 (numeric) close() returns.
    local p = io.popen(cmd .. " 2>&1")
    if not p then return false end
    local _ = p:read("*a")
    local ok = p:close()
    return ok == true or ok == 0
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
--- prefixing keys. Used to satisfy save_metadata's Map<String,String> contract.
---@param dst table<string,string>  destination table (mutated in place)
---@param src table  source map
---@param prefix? string  optional key prefix
local function merge_as_strings(dst, src, prefix)
    for k, v in pairs(src) do
        dst[(prefix or "") .. k] = tostring(v)
    end
end


---@class RioUtils
---@field split_file_name fun(path: string): string, string|nil # Split a path into filename stem and extension.
---@field create_proxy_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Proxy.<ext>` path.
---@field create_thumbnail_name fun(path: string, extension?: string, output_path: string): string # Build a `<dir><stem>-Thumbnail.<ext>` path.
---@field merge_as_strings fun(dst: table, src: table, prefix?: string) # Copy src into dst, stringifying values (for save_metadata).
---@field shell_quote fun(path: any): string # Single-quote a value as one safe shell argument.
---@field run_command fun(cmd: string): string|nil # Run a command, return stdout (nil + logs stderr on failure).
---@field run_quiet_command fun(cmd: string): boolean # Run a command for its side effects; true on success.
---@field join_command fun(parts: (string|nil)[]): string # Join command parts with spaces, dropping nils.
---@field parse_num fun(s: string|nil): number|nil # Parse the leading number from a string.
---@field parse_bytes fun(s: string|nil): number|nil # Parse a byte count with B/K/M/G suffix into bytes.
---@field parse_ratio fun(value: string|nil): number|nil # Parse "num/den" or a plain number.
---@field trim fun(value: any): string # Trim surrounding whitespace.
---@field get_file_extension fun(path: string): string|nil # Lowercase extension without the dot.
---@field format_timestamp fun(total_seconds: number): string # Seconds -> `HH:MM:SS.mmm`.
---@field format_timestamp_for_filename fun(total_seconds: number): string # Seconds -> filename-safe `HH-MM-SS_mmm`.

return {
    split_file_name = split_file_name,
    create_proxy_name = create_proxy_name,
    create_thumbnail_name = create_thumbnail_name,
    merge_as_strings = merge_as_strings,
    shell_quote = shell_quote,
    run_command = run_command,
    run_quiet_command = run_quiet_command,
    join_command = join_command,
    parse_num = parse_num,
    parse_bytes = parse_bytes,
    parse_ratio = parse_ratio,
    trim = trim,
    get_file_extension = get_file_extension,
    format_timestamp = format_timestamp,
    format_timestamp_for_filename = format_timestamp_for_filename,
}
