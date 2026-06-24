--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
-- helper functions for Rio plugin scripts

local function split_file_name(path)
    local file_name = path:match("([^/]+)$") or path
    local stem = file_name:match("(.+)%.([^%.]+)$") or file_name
    local extension = file_name:match("%.([^%.]+)$")
    return stem, extension
end

local function create_proxy_name(path, extension, output_path)
    local stem = split_file_name(path)
    return output_path .. stem .. "-Proxy." .. (extension or "webp")
end

local function create_thumbnail_name(path, extension, output_path)
    local stem = split_file_name(path)
    return output_path .. stem .. "-Thumbnail." .. (extension or "webp")
end

local function shell_quote(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

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

local function join_command(parts)
    local filtered = {}
    for _, part in ipairs(parts) do
        if part then
            filtered[#filtered + 1] = part
        end
    end
    return table.concat(filtered, " ")
end

local function parse_num(s)
    s = (s or ""):match("^%s*(.-)%s*$")
    local num = s:match("^([%d%.]+)")
    return num and tonumber(num) or nil
end

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

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function get_file_extension(path)
    local _, extension = split_file_name(path)
    return extension and extension:lower() or nil
end

local function format_timestamp(total_seconds)
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds - (hours * 3600) - (minutes * 60)
    return string.format("%02d:%02d:%06.3f", hours, minutes, seconds)
end

local function format_timestamp_for_filename(total_seconds)
    return format_timestamp(total_seconds):gsub(":", "-"):gsub("%.", "_")
end

-- coalesce multiple metadata maps and convert to String values)
local function merge_as_strings(dst, src, prefix)
    for k, v in pairs(src) do
        dst[(prefix or "") .. k] = tostring(v)
    end
end



return {
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
