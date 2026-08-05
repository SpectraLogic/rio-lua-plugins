--[[
 * **************************************************************************
 *   Copyright 2014-2026 Spectra Logic Corporation. All Rights Reserved.
 * **************************************************************************
]]--
--[[
  Wrap Rio LuaJit HTTP functions to provide a fetch() API similar to the browser's fetch().
]]--

function fetch(url, opts)
    opts = opts or {}
    local method = (opts.method or "GET"):upper()
    local body = opts.body or ""

    local resp
    if method == "GET" then resp = rio:http_get(url)
    elseif method == "POST" then resp = rio:http_post(url, body)
    elseif method == "PUT" then resp = rio:http_put(url, body)
    elseif method == "PATCH" then resp = rio:http_patch(url, body)
    elseif method == "DELETE" then resp = rio:http_delete(url)
    else error("Unsupported method: " .. method) end

    if type(resp.body) == "function" then
    return {
        status = resp:getStatus(),
        body = resp:getBody(),
        headers = resp:getHeaders(),
    }
end
return resp

end

return {
    fetch = fetch,
}
