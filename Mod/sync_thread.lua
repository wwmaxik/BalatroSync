-- sync_thread.lua
-- BalatroSync: Isolated Background Network Worker (Cloudflare Workers Edition)
-- Runs inside love.thread, executing network requests asynchronously
-- without blocking the main game rendering thread.

local passed_cpath, passed_game_dir, passed_save_dir = ...

require("love.timer")
require("love.thread")

local in_channel = love.thread.getChannel("balatro_sync_in")
local out_channel = love.thread.getChannel("balatro_sync_out")

-- Configure package.cpath to ensure https.dll can be located in Wine / Proton
if passed_cpath and passed_cpath ~= "" then
    package.cpath = package.cpath .. ";" .. passed_cpath
end
if passed_game_dir and passed_game_dir ~= "" then
    package.cpath = package.cpath .. ";" .. passed_game_dir .. "/?.dll;" .. passed_game_dir .. "\\?.dll"
end
package.cpath = package.cpath .. ";./?.dll;?.dll;Z:\\mnt\\games\\Balatro\\?.dll;C:\\mnt\\games\\Balatro\\?.dll"

local log_file_path = nil
if passed_save_dir and passed_save_dir ~= "" then
    log_file_path = passed_save_dir .. "/balatro_sync.log"
end

local function thread_log(msg)
    local line = os.date("[%Y-%m-%d %H:%M:%S] [Worker] ") .. tostring(msg) .. "\n"
    if log_file_path then
        local f = io.open(log_file_path, "a")
        if f then
            f:write(line)
            f:close()
        end
    end
    print(line)
end

thread_log("sync_thread.lua initialized. game_dir=" .. tostring(passed_game_dir) .. ", save_dir=" .. tostring(passed_save_dir))

-- ============================================================================
-- 1. Embedded Pure Lua 5.1 / LuaJIT JSON Engine
-- ============================================================================
local JSON = {}
local escape_map = {
    ['\\'] = '\\\\',
    ['"']  = '\\"',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

function JSON.encode(val)
    local t = type(val)
    if t == 'nil' then
        return 'null'
    elseif t == 'boolean' then
        return val and 'true' or 'false'
    elseif t == 'number' then
        if val ~= val then return 'null' end
        if val >= math.huge or val <= -math.huge then return 'null' end
        if math.floor(val) == val and math.abs(val) < 1e14 then
            return string.format('%d', val)
        else
            return string.format('%.14g', val)
        end
    elseif t == 'string' then
        local s = val:gsub('["\\%z\1-\31]', function(c)
            if escape_map[c] then return escape_map[c] end
            return string.format('\\u%04x', string.byte(c))
        end)
        return '"' .. s .. '"'
    elseif t == 'table' then
        local is_array = false
        local n = 0
        local count = 0
        for k, _ in pairs(val) do
            count = count + 1
            if type(k) == 'number' and k > 0 and math.floor(k) == k then
                if k > n then n = k end
            end
        end
        if count == n and n > 0 then
            is_array = true
        elseif count == 0 and val.__is_array then
            is_array = true
        end

        if is_array then
            local parts = {}
            for i = 1, n do
                parts[i] = JSON.encode(val[i])
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, v in pairs(val) do
                if type(k) == 'string' or type(k) == 'number' then
                    table.insert(parts, JSON.encode(tostring(k)) .. ':' .. JSON.encode(v))
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    else
        return 'null'
    end
end

local function utf8_char(cp)
    if cp < 128 then
        return string.char(cp)
    elseif cp < 2048 then
        return string.char(192 + math.floor(cp / 64), 128 + (cp % 64))
    elseif cp < 65536 then
        return string.char(224 + math.floor(cp / 4096), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
    else
        return string.char(240 + math.floor(cp / 262144), 128 + (math.floor(cp / 4096) % 64), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
    end
end

function JSON.decode(str)
    if type(str) ~= 'string' or str == '' then return nil end
    local idx = 1
    local len = #str

    local function skip_whitespace()
        while idx <= len do
            local b = str:byte(idx)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                idx = idx + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        idx = idx + 1
        local chunks = {}
        local start = idx
        while idx <= len do
            local b = str:byte(idx)
            if b == 34 then
                table.insert(chunks, str:sub(start, idx - 1))
                idx = idx + 1
                return table.concat(chunks)
            elseif b == 92 then
                table.insert(chunks, str:sub(start, idx - 1))
                idx = idx + 1
                local esc = str:sub(idx, idx)
                idx = idx + 1
                if esc == '"' then table.insert(chunks, '"')
                elseif esc == '\\' then table.insert(chunks, '\\')
                elseif esc == '/' then table.insert(chunks, '/')
                elseif esc == 'b' then table.insert(chunks, '\b')
                elseif esc == 'f' then table.insert(chunks, '\f')
                elseif esc == 'n' then table.insert(chunks, '\n')
                elseif esc == 'r' then table.insert(chunks, '\r')
                elseif esc == 't' then table.insert(chunks, '\t')
                elseif esc == 'u' then
                    local hex = str:sub(idx, idx + 3)
                    idx = idx + 4
                    local cp = tonumber(hex, 16) or 63
                    if cp >= 0xD800 and cp <= 0xDBFF and str:sub(idx, idx + 1) == '\\u' then
                        local hex2 = str:sub(idx + 2, idx + 5)
                        local cp2 = tonumber(hex2, 16)
                        if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                            idx = idx + 6
                            cp = 0x10000 + ((cp - 0xD800) * 1024) + (cp2 - 0xDC00)
                        end
                    end
                    table.insert(chunks, utf8_char(cp))
                else
                    table.insert(chunks, esc)
                end
                start = idx
            else
                idx = idx + 1
            end
        end
        return table.concat(chunks)
    end

    local function parse_number()
        local start = idx
        if str:sub(idx, idx) == '-' then idx = idx + 1 end
        while idx <= len and str:byte(idx) >= 48 and str:byte(idx) <= 57 do
            idx = idx + 1
        end
        if idx <= len and str:sub(idx, idx) == '.' then
            idx = idx + 1
            while idx <= len and str:byte(idx) >= 48 and str:byte(idx) <= 57 do
                idx = idx + 1
            end
        end
        if idx <= len and (str:sub(idx, idx) == 'e' or str:sub(idx, idx) == 'E') then
            idx = idx + 1
            if idx <= len and (str:sub(idx, idx) == '+' or str:sub(idx, idx) == '-') then
                idx = idx + 1
            end
            while idx <= len and str:byte(idx) >= 48 and str:byte(idx) <= 57 do
                idx = idx + 1
            end
        end
        local num_str = str:sub(start, idx - 1)
        return tonumber(num_str)
    end

    local function parse_array()
        idx = idx + 1
        local arr = {}
        skip_whitespace()
        if idx <= len and str:sub(idx, idx) == ']' then
            idx = idx + 1
            return arr
        end
        while idx <= len do
            local val = parse_value()
            table.insert(arr, val)
            skip_whitespace()
            local ch = str:sub(idx, idx)
            if ch == ',' then
                idx = idx + 1
            elseif ch == ']' then
                idx = idx + 1
                return arr
            else
                break
            end
        end
        return arr
    end

    local function parse_object()
        idx = idx + 1
        local obj = {}
        skip_whitespace()
        if idx <= len and str:sub(idx, idx) == '}' then
            idx = idx + 1
            return obj
        end
        while idx <= len do
            skip_whitespace()
            if str:sub(idx, idx) ~= '"' then break end
            local key = parse_string()
            skip_whitespace()
            if str:sub(idx, idx) ~= ':' then break end
            idx = idx + 1
            skip_whitespace()
            local val = parse_value()
            obj[key] = val
            skip_whitespace()
            local ch = str:sub(idx, idx)
            if ch == ',' then
                idx = idx + 1
            elseif ch == '}' then
                idx = idx + 1
                return obj
            else
                break
            end
        end
        return obj
    end

    parse_value = function()
        skip_whitespace()
        if idx > len then return nil end
        local ch = str:sub(idx, idx)
        if ch == '"' then
            return parse_string()
        elseif ch == '{' then
            return parse_object()
        elseif ch == '[' then
            return parse_array()
        elseif ch == 't' and str:sub(idx, idx + 3) == 'true' then
            idx = idx + 4
            return true
        elseif ch == 'f' and str:sub(idx, idx + 4) == 'false' then
            idx = idx + 5
            return false
        elseif ch == 'n' and str:sub(idx, idx + 3) == 'null' then
            idx = idx + 4
            return nil
        else
            return parse_number()
        end
    end

    skip_whitespace()
    return parse_value()
end

-- ============================================================================
-- 2. Network Client (Native https.dll + LuaSec + Curl Fallback)
-- ============================================================================
local native_https = nil

local function get_https_module()
    if native_https then return native_https end

    -- 1. Try require("https")
    local ok_req, mod = pcall(require, "https")
    if ok_req and mod and type(mod.request) == "function" then
        thread_log("Loaded native https via require('https')")
        native_https = mod
        return native_https
    else
        thread_log("require('https') failed: " .. tostring(mod))
    end

    -- 2. Try package.loadlib on candidate paths
    local candidate_dlls = {
        "https.dll",
        "./https.dll",
        "Z:\\mnt\\games\\Balatro\\https.dll",
        "C:\\mnt\\games\\Balatro\\https.dll",
    }
    if passed_game_dir and passed_game_dir ~= "" then
        table.insert(candidate_dlls, 1, passed_game_dir .. "/https.dll")
        table.insert(candidate_dlls, 1, passed_game_dir .. "\\https.dll")
    end

    for _, dll_path in ipairs(candidate_dlls) do
        local func, err = package.loadlib(dll_path, "luaopen_https")
        if func then
            local ok_call, res = pcall(func)
            if ok_call and res and type(res.request) == "function" then
                thread_log("Successfully loaded https via loadlib from: " .. dll_path)
                native_https = res
                return native_https
            else
                thread_log("luaopen_https call failed from " .. dll_path .. ": " .. tostring(res))
            end
        end
    end

    return nil
end

local native_https_broken = false
local has_ssl, ssl_https = pcall(require, "ssl.https")
local has_ltn12, ltn12 = pcall(require, "ltn12")

local function curl_request(url, method, headers, body)
    local header_args = ""
    for k, v in pairs(headers or {}) do
        local h_str = string.format('-H "%s: %s"', tostring(k):gsub('"', '\\"'), tostring(v):gsub('"', '\\"'))
        header_args = header_args .. " " .. h_str
    end

    local tmp_file = nil
    local data_arg = ""
    if body and #body > 0 then
        local save_d = (passed_save_dir and passed_save_dir ~= "") and passed_save_dir or "."
        save_d = save_d:gsub("\\", "/")
        tmp_file = save_d .. "/_curl_req.tmp"
        local f = io.open(tmp_file, "wb")
        if f then
            f:write(body)
            f:close()
            data_arg = ' --data-binary "@' .. tmp_file .. '"'
        end
    end

    local curl_cmds = {
        "curl.exe",
        "curl",
        'call "curl.exe"',
        'call "Z:\\mnt\\games\\Balatro\\curl.exe"',
        'call "C:\\windows\\system32\\curl.exe"'
    }
    if passed_game_dir and passed_game_dir ~= "" then
        table.insert(curl_cmds, 1, 'call "' .. passed_game_dir .. '\\curl.exe"')
    end

    local last_err = ""
    for _, curl_bin in ipairs(curl_cmds) do
        local cmd = string.format('%s -s -k -X %s %s%s -w "\n%%{http_code}" "%s"', curl_bin, method, header_args, data_arg, url)
        thread_log("Trying curl (" .. curl_bin .. ")...")
        local pipe = io.popen(cmd, "r")
        if pipe then
            local output = pipe:read("*all")
            pipe:close()
            if output and #output > 0 then
                local body_part, code_str = output:match("^(.-)\r?\n(%d%d%d)%s*$")
                if not code_str then
                    code_str = output:match("^(%d%d%d)%s*$")
                    if code_str then body_part = "" end
                end

                if code_str then
                    local num_code = tonumber(code_str) or 0
                    if num_code >= 100 and num_code < 600 then
                        if tmp_file then os.remove(tmp_file) end
                        thread_log("Curl OK (" .. curl_bin .. "): status=" .. tostring(num_code) .. " len=" .. tostring(#(body_part or "")))
                        return true, num_code, body_part or "", {}
                    end
                end
                last_err = "Curl output parse failed: " .. tostring(output):sub(1, 80)
            else
                last_err = "Curl returned empty output with " .. curl_bin
            end
        else
            last_err = "Failed to open pipe for " .. curl_bin
        end
    end

    if tmp_file then os.remove(tmp_file) end
    return false, 0, last_err
end

local function http_request(url, method, headers, body)
    method = string.upper(method or "GET")
    headers = headers or {}

    thread_log("HTTP " .. method .. " " .. url)

    -- Strategy 1: native Balatro https (https.dll)
    if not native_https_broken then
        local https_mod = get_https_module()
        if https_mod and https_mod.request then
            local opt = {
                method = string.lower(method),
                headers = headers
            }
            if body and #body > 0 then
                opt.data = body
            end
            local ok, code, resp_text, resp_headers = pcall(https_mod.request, url, opt)
            if ok then
                local num_code = tonumber(code) or 0
                if num_code >= 100 and num_code < 600 then
                    thread_log("Native HTTPS OK: status=" .. tostring(num_code) .. " len=" .. tostring(#(resp_text or "")))
                    return true, num_code, resp_text or "", resp_headers or {}
                else
                    thread_log("Native HTTPS returned non-HTTP status " .. tostring(num_code) .. " (Wine WinINet TLS failure). Switching to curl.")
                    native_https_broken = true
                end
            else
                thread_log("Native HTTPS error: " .. tostring(code) .. ". Switching to curl.")
                native_https_broken = true
            end
        end
    end

    -- Strategy 2: ssl.https with ltn12
    if has_ssl and has_ltn12 then
        local resp_chunks = {}
        local req_headers = {}
        for k, v in pairs(headers) do req_headers[k] = v end
        if body and #body > 0 then
            req_headers["Content-Length"] = tostring(#body)
        end
        local req_params = {
            url = url,
            method = method,
            headers = req_headers,
            sink = ltn12.sink.table(resp_chunks),
        }
        if body and #body > 0 then
            req_params.source = ltn12.source.string(body)
        end
        local ok, code, resp_headers, status = pcall(ssl_https.request, req_params)
        if ok then
            local resp_text = table.concat(resp_chunks)
            local num_code = tonumber(code) or (code == 1 and 200 or 0)
            if num_code >= 100 and num_code < 600 then
                thread_log("LuaSec HTTPS OK: status=" .. tostring(num_code))
                return true, num_code, resp_text, resp_headers or {}
            end
        else
            thread_log("LuaSec HTTPS error: " .. tostring(code))
        end
    end

    -- Strategy 3: curl CLI fallback (using bundled Windows curl.exe)
    local ok_c, code_c, body_c, h_c = curl_request(url, method, headers, body)
    if ok_c and code_c >= 100 and code_c < 600 then
        return true, code_c, body_c, h_c
    else
        thread_log("Curl fallback failed: code=" .. tostring(code_c) .. ", err=" .. tostring(body_c))
    end

    return false, 0, "All HTTPS methods failed (native https.dll returned 0, curl failed)"
end

local function clean_url(url)
    if not url then return "" end
    return url:gsub("/+$", "")
end

local function get_auth_headers(config)
    local token = config.auth_token or ""
    return {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
        ["X-Auth-Token"] = token
    }
end

-- ============================================================================
-- 3. Cloudflare Worker Operations
-- ============================================================================

local function handle_check_and_download(req, config)
    local profile_id = req.profile_id or 1
    local local_ts = tonumber(req.local_timestamp) or 0
    local base_url = clean_url(config.worker_url)

    if base_url == "" or base_url:find("your%-subdomain") then
        out_channel:push({
            type = "AUTH_ERROR",
            operation = "CHECK_AND_DOWNLOAD",
            profile_id = profile_id,
            error = "Worker URL is not configured in config.json!"
        })
        return
    end

    local headers = get_auth_headers(config)

    -- 1. Fast status check: GET /profile/:id/status
    local status_url = string.format("%s/profile/%d/status", base_url, profile_id)
    local ok_s, code_s, body_s = http_request(status_url, "GET", headers)

    if not ok_s then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "CHECK_STATUS",
            profile_id = profile_id,
            error = "Connection error: " .. tostring(body_s)
        })
        return
    end

    if code_s == 401 then
        out_channel:push({
            type = "AUTH_ERROR",
            operation = "CHECK_STATUS",
            profile_id = profile_id,
            error = "Invalid auth_token (401 Unauthorized)"
        })
        return
    end

    if code_s ~= 200 then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "CHECK_STATUS",
            profile_id = profile_id,
            error = string.format("Worker returned HTTP %d: %s", code_s, tostring(body_s))
        })
        return
    end

    local status_obj = JSON.decode(body_s)
    if not status_obj or type(status_obj) ~= "table" then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "PARSE_STATUS",
            profile_id = profile_id,
            error = "Worker returned invalid JSON"
        })
        return
    end

    -- 2. Check Session Lock Conflict
    local sess = status_obj.session
    if sess and sess.device_id and sess.device_id ~= config.device_id then
        local last_seen = tonumber(sess.last_seen) or 0
        local time_diff = os.time() - last_seen
        if time_diff < 180 and time_diff >= 0 then
            out_channel:push({
                type = "SESSION_CONFLICT",
                operation = "CHECK_AND_DOWNLOAD",
                profile_id = profile_id,
                remote_device = sess.device_id,
                last_seen = last_seen,
                time_diff = time_diff
            })
            return
        end
    end

    -- 3. Check Timestamp
    local remote_ts = tonumber(status_obj.timestamp) or 0
    if remote_ts <= 0 then
        out_channel:push({
            type = "UP_TO_DATE",
            profile_id = profile_id,
            reason = "no_cloud_save",
            remote_ts = 0,
            local_ts = local_ts
        })
        return
    end

    -- 4. If remote is newer by > 2 seconds, download full save payload
    if remote_ts > local_ts + 2 then
        local save_url = string.format("%s/profile/%d", base_url, profile_id)
        local ok_f, code_f, body_f = http_request(save_url, "GET", headers)
        if not ok_f or code_f ~= 200 then
            out_channel:push({
                type = "SYNC_ERROR",
                operation = "DOWNLOAD_PAYLOAD",
                profile_id = profile_id,
                error = "Failed to download save payload: " .. tostring(body_f)
            })
            return
        end

        local payload = JSON.decode(body_f)
        if not payload or type(payload) ~= "table" then
            out_channel:push({
                type = "SYNC_ERROR",
                operation = "PARSE_PAYLOAD",
                profile_id = profile_id,
                error = "Corrupted save payload"
            })
            return
        end

        out_channel:push({
            type = "DOWNLOAD_COMPLETE",
            profile_id = profile_id,
            payload = payload,
            is_force = false
        })
    else
        out_channel:push({
            type = "UP_TO_DATE",
            profile_id = profile_id,
            remote_ts = remote_ts,
            local_ts = local_ts
        })
    end
end

local function handle_force_download(req, config)
    local profile_id = req.profile_id or 1
    local base_url = clean_url(config.worker_url)
    local headers = get_auth_headers(config)

    local save_url = string.format("%s/profile/%d", base_url, profile_id)
    local ok_f, code_f, body_f = http_request(save_url, "GET", headers)
    if not ok_f or code_f ~= 200 then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "FORCE_DOWNLOAD",
            profile_id = profile_id,
            error = "Failed to download save payload: " .. tostring(body_f)
        })
        return
    end

    local payload = JSON.decode(body_f)
    if not payload or type(payload) ~= "table" then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "FORCE_DOWNLOAD",
            profile_id = profile_id,
            error = "Invalid or empty payload"
        })
        return
    end

    out_channel:push({
        type = "DOWNLOAD_COMPLETE",
        profile_id = profile_id,
        payload = payload,
        is_force = true
    })
end

local function handle_upload(req, config, is_force)
    local profile_id = req.profile_id or 1
    local payload = req.payload
    local base_url = clean_url(config.worker_url)

    if not payload or type(payload) ~= "table" then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "UPLOAD",
            profile_id = profile_id,
            error = "Invalid payload in UPLOAD"
        })
        return
    end

    local now_ts = os.time()
    payload.timestamp = now_ts
    payload.device_id = config.device_id or "UNKNOWN_DEVICE"

    local upload_url = string.format("%s/profile/%d%s", base_url, profile_id, is_force and "?force=true" or "")
    local headers = get_auth_headers(config)
    local encoded_body = JSON.encode(payload)

    local ok_u, code_u, body_u = http_request(upload_url, "PUT", headers, encoded_body)
    if not ok_u then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "UPLOAD",
            profile_id = profile_id,
            error = "Network error during upload: " .. tostring(body_u)
        })
        return
    end

    if code_u == 409 then
        local err_obj = JSON.decode(body_u) or {}
        out_channel:push({
            type = "SESSION_CONFLICT",
            operation = "UPLOAD",
            profile_id = profile_id,
            remote_device = err_obj.remote_device or "Unknown PC",
            last_seen = err_obj.last_seen or 0,
            time_diff = err_obj.time_diff or 0
        })
        return
    end

    if code_u == 401 then
        out_channel:push({
            type = "AUTH_ERROR",
            operation = "UPLOAD",
            profile_id = profile_id,
            error = "Invalid auth_token (401 Unauthorized)"
        })
        return
    end

    if code_u ~= 200 then
        out_channel:push({
            type = "SYNC_ERROR",
            operation = "UPLOAD",
            profile_id = profile_id,
            error = string.format("Worker returned HTTP %d: %s", code_u, tostring(body_u))
        })
        return
    end

    out_channel:push({
        type = "UPLOAD_COMPLETE",
        profile_id = profile_id,
        timestamp = now_ts,
        is_force = is_force,
        is_active = payload.is_active
    })
end

local function handle_heartbeat(req, config)
    local profile_id = req.profile_id or 1
    local base_url = clean_url(config.worker_url)
    local headers = get_auth_headers(config)

    local session_url = string.format("%s/profile/%d/session", base_url, profile_id)
    local body = JSON.encode({ device_id = config.device_id })
    http_request(session_url, "PUT", headers, body)
end

local function handle_takeover(req, config)
    local profile_id = req.profile_id or 1
    local base_url = clean_url(config.worker_url)
    local headers = get_auth_headers(config)

    local takeover_url = string.format("%s/profile/%d/takeover", base_url, profile_id)
    local body = JSON.encode({ device_id = config.device_id })
    http_request(takeover_url, "POST", headers, body)
end

-- ============================================================================
-- 4. Main Worker Thread Loop
-- ============================================================================
local current_config = {
    worker_url = "",
    auth_token = "",
    device_id = "PC-PRIMARY",
    sync_meta = true
}

local running = true

while running do
    local req = in_channel:pop()
    if req then
        local op = req.type
        thread_log("Processing operation: " .. tostring(op))

        local ok, err = pcall(function()
            if op == "INIT" then
                if req.config then
                    for k, v in pairs(req.config) do
                        current_config[k] = v
                    end
                end
                if req.game_dir and req.game_dir ~= "" then
                    passed_game_dir = req.game_dir
                    package.cpath = package.cpath .. ";" .. req.game_dir .. "/?.dll;" .. req.game_dir .. "\\?.dll"
                end
                if req.save_dir and req.save_dir ~= "" then
                    passed_save_dir = req.save_dir
                    log_file_path = passed_save_dir .. "/balatro_sync.log"
                end
                out_channel:push({ type = "INIT_OK" })

            elseif op == "CHECK_AND_DOWNLOAD" then
                handle_check_and_download(req, current_config)

            elseif op == "UPLOAD" then
                handle_upload(req, current_config, false)

            elseif op == "FORCE_UPLOAD" then
                handle_upload(req, current_config, true)

            elseif op == "FORCE_DOWNLOAD" then
                handle_force_download(req, current_config)

            elseif op == "HEARTBEAT" then
                handle_heartbeat(req, current_config)

            elseif op == "TAKEOVER" then
                handle_takeover(req, current_config)

            elseif op == "SHUTDOWN" then
                running = false
                out_channel:push({ type = "SHUTDOWN_ACK" })
            end
        end)

        if not ok then
            thread_log("Unhandled error in operation '" .. tostring(op) .. "': " .. tostring(err))
            out_channel:push({
                type = "SYNC_ERROR",
                operation = op,
                error = tostring(err)
            })
        end
    else
        love.timer.sleep(0.05)
    end
end
