-- sync_mod.lua
-- BalatroSync: Main Game Integration, Data Protection, UI & Cloud Synchronization
-- Cloudflare Worker Edition with Full In-Game UI Authorization & Multi-Platform Support

BalatroSync = BalatroSync or {}

-- ============================================================================
-- 1. Embedded JSON Parser & Serializer for Main Thread (Pure Lua 5.1)
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
-- 2. State & Variables
-- ============================================================================
BalatroSync.version = "1.2.0"
BalatroSync.config = {
    worker_url = "",
    auth_token = "",
    device_id = "PC-PRIMARY",
    sync_meta = true
}

BalatroSync.status = "IDLE"
BalatroSync.status_text = "[ BalatroSync: Ready ]"
BalatroSync.status_color = {0.4, 0.8, 0.5, 1.0}
BalatroSync.last_sync_time = 0
BalatroSync.pending_upload = false
BalatroSync.debounce_timer = 0
BalatroSync.heartbeat_timer = 0
BalatroSync.session_conflict = nil
BalatroSync.toasts = {}
BalatroSync.steam_warned = false
BalatroSync.in_channel = nil
BalatroSync.out_channel = nil
BalatroSync.worker_thread = nil
BalatroSync.initialized = false
BalatroSync.current_profile = 1

local device_presets = {"PC-PRIMARY", "PC-SECONDARY", "LAPTOP", "STEAM-DECK", "PC-HOME", "PC-WORK"}

-- ============================================================================
-- 3. Logging & File System Helpers
-- ============================================================================
function BalatroSync.log(msg)
    local line = os.date("[%Y-%m-%d %H:%M:%S] [Main] ") .. tostring(msg) .. "\n"
    if love.filesystem and love.filesystem.getSaveDirectory then
        local p = love.filesystem.getSaveDirectory() .. "/balatro_sync.log"
        local f = io.open(p, "a")
        if f then
            f:write(line)
            f:close()
        end
    end
    print(line)
end

local function read_external_file(rel_path)
    if love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(rel_path) then
        local data = love.filesystem.read(rel_path)
        if data then return data end
    end
    if love.filesystem and love.filesystem.getSaveDirectory then
        local full_path = love.filesystem.getSaveDirectory() .. "/" .. rel_path
        local f = io.open(full_path, "rb")
        if f then
            local data = f:read("*all")
            f:close()
            return data
        end
    end
    local f = io.open(rel_path, "rb")
    if f then
        local data = f:read("*all")
        f:close()
        return data
    end
    local game_dir = (love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()) or ""
    if game_dir ~= "" then
        local f = io.open(game_dir .. "/" .. rel_path, "rb")
        if f then
            local data = f:read("*all")
            f:close()
            return data
        end
    end
    return nil
end

function BalatroSync.save_config()
    local serialized = JSON.encode(BalatroSync.config)
    BalatroSync.log("Saving configuration: " .. tostring(serialized))

    -- 1. Save to Balatro save directory
    if love.filesystem and love.filesystem.getSaveDirectory then
        local save_mod_dir = love.filesystem.getSaveDirectory() .. "/Mods/BalatroSync"
        if not love.filesystem.getInfo("Mods/BalatroSync") then
            pcall(function() love.filesystem.createDirectory("Mods/BalatroSync") end)
        end
        local f1 = io.open(save_mod_dir .. "/config.json", "wb")
        if f1 then
            f1:write(serialized)
            f1:close()
        end
    end

    -- 2. Save to game folder Mods/BalatroSync/config.json
    local f2 = io.open("Mods/BalatroSync/config.json", "wb")
    if f2 then
        f2:write(serialized)
        f2:close()
    end

    -- 3. Send update event to worker thread
    if BalatroSync.in_channel then
        BalatroSync.in_channel:push({
            type = "INIT",
            config = BalatroSync.config
        })
    end
end

local function get_profile_paths(profile_id)
    profile_id = tonumber(profile_id) or 1
    if profile_id == 1 then
        return {
            primary = "save.jkr",
            secondary = "1/save.jkr",
            dir = "",
            meta = "meta.jkr",
            meta_sec = "1/meta.jkr"
        }
    else
        local p_str = tostring(profile_id)
        return {
            primary = p_str .. "/save.jkr",
            secondary = nil,
            dir = p_str,
            meta = p_str .. "/meta.jkr",
            meta_sec = nil
        }
    end
end

-- ============================================================================
-- 4. Mod Guard (Check Active Mods via SMODS)
-- ============================================================================
local function get_active_mod_ids()
    local mods = {}
    if SMODS and SMODS.Mods then
        for k, v in pairs(SMODS.Mods) do
            local mod_id = (type(v) == "table" and (v.id or v.name)) or tostring(k)
            table.insert(mods, mod_id)
        end
    end
    return mods
end

local function verify_mods_compatibility(required_mods)
    if not required_mods or #required_mods == 0 then
        return true, {}
    end
    local installed = {}
    if SMODS and SMODS.Mods then
        for k, v in pairs(SMODS.Mods) do
            local mod_id = (type(v) == "table" and (v.id or v.name)) or tostring(k)
            installed[mod_id] = true
        end
    end
    local missing = {}
    for _, mod_id in ipairs(required_mods) do
        if mod_id ~= "BalatroSync" and not installed[mod_id] then
            table.insert(missing, mod_id)
        end
    end
    if #missing > 0 then
        return false, missing
    end
    return true, {}
end

-- ============================================================================
-- 5. Toast Notifications & HUD System (English ASCII Safe Rendering)
-- ============================================================================
function BalatroSync.show_toast(text, color, duration)
    table.insert(BalatroSync.toasts, {
        text = text,
        color = color or {1, 1, 1, 1},
        timer = duration or 4.5,
        max_time = duration or 4.5
    })
    if #BalatroSync.toasts > 4 then
        table.remove(BalatroSync.toasts, 1)
    end
end

local function set_status(status, text, color)
    BalatroSync.status = status
    BalatroSync.status_text = text
    BalatroSync.status_color = color or {0.8, 0.8, 0.8, 1.0}
end

-- ============================================================================
-- 6. Atomic Save System & Data Integrity
-- ============================================================================
local function atomic_write_file(filepath, content)
    local tmp_path = filepath .. ".tmp"
    local bak_path = filepath .. ".bak"

    local dir = filepath:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not love.filesystem.getInfo(dir) then
        love.filesystem.createDirectory(dir)
    end

    local success_tmp, err_tmp = love.filesystem.write(tmp_path, content)
    if not success_tmp then
        return false, "Failed to write temp file: " .. tostring(err_tmp)
    end

    if love.filesystem.getInfo(filepath) then
        local current_data = love.filesystem.read(filepath)
        if current_data then
            love.filesystem.write(bak_path, current_data)
        end
    end

    love.filesystem.remove(filepath)
    local success_final, err_final = love.filesystem.write(filepath, content)
    love.filesystem.remove(tmp_path)

    if not success_final then
        if love.filesystem.getInfo(bak_path) then
            local bak_data = love.filesystem.read(bak_path)
            if bak_data then love.filesystem.write(filepath, bak_data) end
        end
        return false, "Failed to replace save file: " .. tostring(err_final)
    end

    return true
end

local function apply_downloaded_save(profile_id, payload)
    if not payload then return false end

    local paths = get_profile_paths(profile_id)

    if payload.is_active == false or not payload.data or payload.data == "" then
        BalatroSync.log("Remote run is inactive or finished. Removing local save.")
        if love.filesystem.getInfo(paths.primary) then
            love.filesystem.remove(paths.primary)
        end
        if paths.secondary and love.filesystem.getInfo(paths.secondary) then
            love.filesystem.remove(paths.secondary)
        end
        G.SAVED_GAME = nil
        if G.STATE == G.STATES.MENU then
            pcall(function() G:main_menu() end)
        end
        BalatroSync.show_toast("[BalatroSync] Remote run finished. Save cleared.", {0.6, 0.8, 1, 1})
        set_status("SYNCED", "[ BalatroSync: Synced ]", {0.3, 0.9, 0.4, 1.0})
        return true
    end

    local compatible, missing = verify_mods_compatibility(payload.mods)
    if not compatible then
        local missing_str = table.concat(missing, ", ")
        BalatroSync.log("Mod mismatch: " .. missing_str)
        BalatroSync.show_toast("[BalatroSync] Missing required mods: " .. missing_str, {1.0, 0.3, 0.2, 1.0}, 7.0)
        set_status("ERROR", "[ BalatroSync: Mod Mismatch ]", {1.0, 0.3, 0.2, 1.0})
        return false
    end

    local ok_decode, decoded = pcall(love.data.decode, "string", "base64", payload.data)
    if not ok_decode or not decoded then
        BalatroSync.log("Failed to decode base64 save data")
        BalatroSync.show_toast("[BalatroSync] Error decoding Base64 save data!", {1.0, 0.2, 0.2, 1.0})
        set_status("ERROR", "[ BalatroSync: Data Error ]", {1.0, 0.2, 0.2, 1.0})
        return false
    end

    if tonumber(payload.size) and #decoded ~= tonumber(payload.size) then
        BalatroSync.log(string.format("Size mismatch: decoded=%d expected=%d", #decoded, tonumber(payload.size)))
        BalatroSync.show_toast(string.format("[BalatroSync] Size mismatch: %d != %d", #decoded, payload.size), {1.0, 0.2, 0.2, 1.0})
        set_status("ERROR", "[ BalatroSync: File Corrupted ]", {1.0, 0.2, 0.2, 1.0})
        return false
    end

    local ok_write, write_err = atomic_write_file(paths.primary, decoded)
    if not ok_write then
        BalatroSync.log("Atomic write failed: " .. tostring(write_err))
        BalatroSync.show_toast("[BalatroSync] " .. tostring(write_err), {1.0, 0.2, 0.2, 1.0})
        set_status("ERROR", "[ BalatroSync: Write Error ]", {1.0, 0.2, 0.2, 1.0})
        return false
    end

    if paths.secondary and (love.filesystem.getInfo("1") or love.filesystem.getInfo(paths.secondary)) then
        atomic_write_file(paths.secondary, decoded)
    end

    if BalatroSync.config.sync_meta and payload.meta_jkr and payload.meta_jkr ~= "" then
        local ok_m, decoded_meta = pcall(love.data.decode, "string", "base64", payload.meta_jkr)
        if ok_m and decoded_meta then
            atomic_write_file(paths.meta, decoded_meta)
            if paths.meta_sec and love.filesystem.getInfo("1") then
                atomic_write_file(paths.meta_sec, decoded_meta)
            end
        end
    end

    if G.STATE == G.STATES.MENU then
        local raw = get_compressed(paths.primary)
        if raw then
            local ok_u, unpacked = pcall(STR_UNPACK, raw)
            if ok_u and unpacked then
                G.SAVED_GAME = unpacked
            end
        end
        pcall(function() G:main_menu() end)
    end

    BalatroSync.last_sync_time = os.time()
    set_status("SYNCED", "[ BalatroSync: Synced ]", {0.3, 0.9, 0.4, 1.0})
    BalatroSync.show_toast("[BalatroSync] Run downloaded from cloud!", {0.3, 0.9, 0.4, 1.0})
    BalatroSync.log("Save successfully applied.")
    return true
end

-- ============================================================================
-- 7. Network Worker Dispatchers
-- ============================================================================
local function read_local_save(profile_id)
    local paths = get_profile_paths(profile_id)
    local target = paths.primary
    if not love.filesystem.getInfo(target) and paths.secondary and love.filesystem.getInfo(paths.secondary) then
        target = paths.secondary
    end

    if not love.filesystem.getInfo(target) then
        return nil, nil
    end

    local raw = love.filesystem.read(target)
    if not raw or #raw == 0 then return nil, nil end

    local info = love.filesystem.getInfo(target)
    local mod_time = (info and info.modtime) or os.time()

    return raw, mod_time
end

function BalatroSync.check_and_download(profile_id)
    profile_id = profile_id or (G.SETTINGS and G.SETTINGS.profile) or 1
    BalatroSync.current_profile = profile_id

    local raw, mod_time = read_local_save(profile_id)
    set_status("DOWNLOADING", "[ BalatroSync: Checking Cloud... ]", {0.3, 0.8, 1.0, 1.0})

    BalatroSync.log("Dispatching CHECK_AND_DOWNLOAD (profile=" .. tostring(profile_id) .. ", mod_time=" .. tostring(mod_time) .. ")")
    BalatroSync.in_channel:push({
        type = "CHECK_AND_DOWNLOAD",
        profile_id = profile_id,
        local_timestamp = mod_time or 0
    })
end

function BalatroSync.force_download(profile_id)
    profile_id = profile_id or (G.SETTINGS and G.SETTINGS.profile) or 1
    set_status("DOWNLOADING", "[ BalatroSync: Downloading... ]", {0.3, 0.8, 1.0, 1.0})
    BalatroSync.log("Dispatching FORCE_DOWNLOAD (profile=" .. tostring(profile_id) .. ")")
    BalatroSync.in_channel:push({
        type = "FORCE_DOWNLOAD",
        profile_id = profile_id
    })
end

function BalatroSync.dispatch_upload(is_force)
    local profile_id = (G.SETTINGS and G.SETTINGS.profile) or 1
    BalatroSync.current_profile = profile_id

    local raw, mod_time = read_local_save(profile_id)
    local is_active = (raw ~= nil and #raw > 0)

    local meta_preview = {}
    if G.GAME then
        meta_preview.ante = (G.GAME.round_resets and G.GAME.round_resets.ante) or 1
        meta_preview.stake = G.GAME.stake or 1
        meta_preview.dollars = G.GAME.dollars or 0
        meta_preview.round = (G.GAME.round_resets and G.GAME.round_resets.round) or 0
        if G.GAME.selected_back then
            meta_preview.deck = G.GAME.selected_back.name or "Deck"
        end
    end

    local b64_data = ""
    local data_size = 0
    if is_active and raw then
        b64_data = love.data.encode("string", "base64", raw)
        data_size = #raw
    end

    local b64_meta = ""
    if BalatroSync.config.sync_meta then
        local paths = get_profile_paths(profile_id)
        if love.filesystem.getInfo(paths.meta) then
            local meta_raw = love.filesystem.read(paths.meta)
            if meta_raw and #meta_raw > 0 then
                b64_meta = love.data.encode("string", "base64", meta_raw)
            end
        end
    end

    local payload = {
        is_active = is_active,
        data = b64_data,
        size = data_size,
        meta = meta_preview,
        mods = get_active_mod_ids(),
        meta_jkr = b64_meta
    }

    set_status("UPLOADING", "[ BalatroSync: Uploading... ]", {0.2, 0.8, 1.0, 1.0})
    BalatroSync.log("Dispatching UPLOAD (profile=" .. tostring(profile_id) .. ", is_active=" .. tostring(is_active) .. ", size=" .. tostring(data_size) .. ")")

    BalatroSync.in_channel:push({
        type = is_force and "FORCE_UPLOAD" or "UPLOAD",
        profile_id = profile_id,
        payload = payload
    })

    BalatroSync.pending_upload = false
    BalatroSync.debounce_timer = 0
end

function BalatroSync.queue_checkpoint_upload(reason)
    BalatroSync.pending_upload = true
    BalatroSync.debounce_timer = 2.5
    BalatroSync.upload_reason = reason
    set_status("PENDING", "[ BalatroSync: Pending Save... ]", {0.9, 0.7, 0.2, 1.0})
    BalatroSync.log("Queued checkpoint upload (reason: " .. tostring(reason) .. ")")
end

-- ============================================================================
-- 8. Game Event Hooks (Smart Triggers)
-- ============================================================================
function BalatroSync.on_save_run()
    BalatroSync.queue_checkpoint_upload("save_run")
end

function BalatroSync.on_round_eval()
    BalatroSync.queue_checkpoint_upload("round_win")
end

function BalatroSync.on_shop_exit()
    BalatroSync.queue_checkpoint_upload("shop_exit")
end

function BalatroSync.on_menu()
    BalatroSync.queue_checkpoint_upload("menu_exit")
end

function BalatroSync.on_remove_save()
    BalatroSync.dispatch_upload(false)
end

function BalatroSync.on_quit()
    BalatroSync.log("love.quit detected, ensuring final upload.")
    if BalatroSync.pending_upload or BalatroSync.status == "UPLOADING" then
        if BalatroSync.pending_upload then
            BalatroSync.dispatch_upload(false)
        end

        local start_t = love.timer.getTime()
        while (love.timer.getTime() - start_t < 1.8) do
            local msg = BalatroSync.out_channel:pop()
            if msg then
                if msg.type == "UPLOAD_COMPLETE" or msg.type == "SYNC_ERROR" or msg.type == "AUTH_ERROR" then
                    break
                end
            end
            love.timer.sleep(0.04)
        end
    end

    if BalatroSync.in_channel then
        BalatroSync.in_channel:push({ type = "SHUTDOWN" })
    end
end

-- ============================================================================
-- 9. Initialization & Worker Startup
-- ============================================================================
function BalatroSync.init()
    if BalatroSync.initialized then return end

    BalatroSync.log("BalatroSync v" .. tostring(BalatroSync.version) .. " initializing...")

    local raw_cfg = read_external_file("Mods/BalatroSync/config.json")
    if raw_cfg then
        local parsed = JSON.decode(raw_cfg)
        if parsed and type(parsed) == "table" then
            for k, v in pairs(parsed) do
                BalatroSync.config[k] = v
            end
            BalatroSync.log("Config loaded. Worker URL: " .. tostring(BalatroSync.config.worker_url) .. ", Device: " .. tostring(BalatroSync.config.device_id))
        end
    else
        BalatroSync.log("Warning: config.json not found!")
    end

    BalatroSync.in_channel = love.thread.getChannel("balatro_sync_in")
    BalatroSync.out_channel = love.thread.getChannel("balatro_sync_out")

    -- Clear stale messages
    while BalatroSync.in_channel:pop() do end
    while BalatroSync.out_channel:pop() do end

    local thread_code = read_external_file("Mods/BalatroSync/sync_thread.lua")
    if thread_code then
        local game_dir = ""
        if love.filesystem and love.filesystem.getSourceBaseDirectory then
            game_dir = love.filesystem.getSourceBaseDirectory() or ""
        end
        if game_dir == "" and love.filesystem and love.filesystem.getWorkingDirectory then
            game_dir = love.filesystem.getWorkingDirectory() or ""
        end
        local save_dir = (love.filesystem and love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ""
        local cpath = package.cpath or ""

        BalatroSync.log("Spawning worker thread. Game dir: '" .. tostring(game_dir) .. "', Save dir: '" .. tostring(save_dir) .. "'")

        BalatroSync.worker_thread = love.thread.newThread(thread_code)
        BalatroSync.worker_thread:start(cpath, game_dir, save_dir)

        BalatroSync.in_channel:push({
            type = "INIT",
            config = BalatroSync.config,
            game_dir = game_dir,
            save_dir = save_dir
        })
    else
        BalatroSync.log("Error: sync_thread.lua not found!")
        set_status("ERROR", "[ BalatroSync: Thread Missing ]", {1, 0.3, 0.3, 1})
    end

    BalatroSync.initialized = true

    if love.filesystem.getInfo("steam_autocloud.vdf") or (G.STEAM and not G.SETTINGS.balatro_sync_steam_warned) then
        BalatroSync.steam_warned = true
        BalatroSync.show_toast("[BalatroSync] Steam Cloud detected! Disable it in Steam properties.", {1.0, 0.6, 0.2, 1.0}, 8.0)
    end

    BalatroSync.check_and_download((G.SETTINGS and G.SETTINGS.profile) or 1)
end

-- ============================================================================
-- 10. Frame Update Loop (Game:update)
-- ============================================================================
function BalatroSync.update(dt)
    if not BalatroSync.initialized then return end

    -- Check if worker thread encountered an unhandled crash
    if BalatroSync.worker_thread then
        local thr_err = BalatroSync.worker_thread:getError()
        if thr_err then
            BalatroSync.log("FATAL: Worker thread crashed: " .. tostring(thr_err))
            set_status("ERROR", "[ BalatroSync: Thread Crash ]", {1.0, 0.2, 0.2, 1.0})
            BalatroSync.show_toast("[BalatroSync] Thread crash: " .. tostring(thr_err):sub(1, 45), {1.0, 0.2, 0.2, 1.0}, 6.0)
        end
    end

    while true do
        local msg = BalatroSync.out_channel:pop()
        if not msg then break end

        local m_type = msg.type
        BalatroSync.log("Worker event: " .. tostring(m_type))

        if m_type == "INIT_OK" then
            set_status("IDLE", "[ BalatroSync: Ready ]", {0.4, 0.8, 0.5, 1.0})

        elseif m_type == "UP_TO_DATE" then
            set_status("SYNCED", "[ BalatroSync: Synced ]", {0.3, 0.9, 0.4, 1.0})

        elseif m_type == "DOWNLOAD_COMPLETE" then
            apply_downloaded_save(msg.profile_id or 1, msg.payload)

        elseif m_type == "UPLOAD_COMPLETE" then
            BalatroSync.last_sync_time = msg.timestamp or os.time()
            set_status("SYNCED", "[ BalatroSync: Synced ]", {0.3, 0.9, 0.4, 1.0})
            BalatroSync.show_toast("[BalatroSync] Progress saved to cloud!", {0.3, 0.9, 0.4, 1.0})

        elseif m_type == "SESSION_CONFLICT" then
            BalatroSync.session_conflict = {
                profile_id = msg.profile_id,
                remote_device = msg.remote_device,
                last_seen = msg.last_seen,
                time_diff = msg.time_diff
            }
            set_status("CONFLICT", "[ BalatroSync: Session Conflict! ]", {1.0, 0.5, 0.1, 1.0})
            BalatroSync.show_toast(string.format("[BalatroSync] Active on '%s'! Open Settings to Take Over.", tostring(msg.remote_device)), {1.0, 0.5, 0.1, 1.0}, 8.0)

        elseif m_type == "AUTH_ERROR" then
            set_status("ERROR", "[ BalatroSync: Auth Error ]", {1.0, 0.25, 0.25, 1.0})
            BalatroSync.show_toast("[BalatroSync] Auth Error: " .. tostring(msg.error), {1.0, 0.25, 0.25, 1.0}, 6.0)

        elseif m_type == "SYNC_ERROR" then
            set_status("ERROR", "[ BalatroSync: Net Error ]", {1.0, 0.3, 0.3, 1.0})
            BalatroSync.show_toast("[BalatroSync] Net Error: " .. tostring(msg.error), {1.0, 0.3, 0.3, 1.0}, 5.0)
        end
    end

    if BalatroSync.pending_upload then
        BalatroSync.debounce_timer = BalatroSync.debounce_timer - dt
        if BalatroSync.debounce_timer <= 0 then
            BalatroSync.dispatch_upload(false)
        end
    end

    if G.STAGE == G.STAGES.RUN then
        BalatroSync.heartbeat_timer = BalatroSync.heartbeat_timer + dt
        if BalatroSync.heartbeat_timer >= 60 then
            BalatroSync.heartbeat_timer = 0
            BalatroSync.in_channel:push({
                type = "HEARTBEAT",
                profile_id = (G.SETTINGS and G.SETTINGS.profile) or 1
            })
        end
    end

    for i = #BalatroSync.toasts, 1, -1 do
        local toast = BalatroSync.toasts[i]
        toast.timer = toast.timer - dt
        if toast.timer <= 0 then
            table.remove(BalatroSync.toasts, i)
        end
    end
end

-- ============================================================================
-- 11. HUD Rendering & Toasts (love.draw)
-- ============================================================================
function BalatroSync.draw()
    if not BalatroSync.initialized then return end

    local font = love.graphics.getFont()
    love.graphics.push("all")

    local text = BalatroSync.status_text
    local col = BalatroSync.status_color
    local screen_w = love.graphics.getWidth()

    local str_w = font and font:getWidth(text) or 220
    local str_h = font and font:getHeight() or 18

    local pad_x = 10
    local pad_y = 6
    local box_w = str_w + pad_x * 2
    local box_h = str_h + pad_y * 2
    local pos_x = screen_w - box_w - 16
    local pos_y = 14

    love.graphics.setColor(0.08, 0.08, 0.12, 0.82)
    love.graphics.rectangle("fill", pos_x, pos_y, box_w, box_h, 5, 5)

    love.graphics.setColor(col[1], col[2], col[3], 0.6)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", pos_x, pos_y, box_w, box_h, 5, 5)

    love.graphics.setColor(col[1], col[2], col[3], col[4] or 1.0)
    love.graphics.print(text, pos_x + pad_x, pos_y + pad_y)

    local toast_y = pos_y + box_h + 10
    for _, t in ipairs(BalatroSync.toasts) do
        local alpha = math.min(1.0, t.timer / 0.5)
        local t_text = t.text
        local tw = font and font:getWidth(t_text) or 300
        local th = font and font:getHeight() or 18
        local t_bx = tw + 20
        local t_by = th + 10
        local tx = screen_w - t_bx - 16

        love.graphics.setColor(0.12, 0.12, 0.16, 0.9 * alpha)
        love.graphics.rectangle("fill", tx, toast_y, t_bx, t_by, 4, 4)

        love.graphics.setColor(t.color[1], t.color[2], t.color[3], (t.color[4] or 1.0) * alpha)
        love.graphics.rectangle("line", tx, toast_y, t_bx, t_by, 4, 4)
        love.graphics.print(t_text, tx + 10, toast_y + 5)

        toast_y = toast_y + t_by + 6
    end

    love.graphics.pop()
end

-- ============================================================================
-- 12. In-Game UI Authorization & Settings Tab
-- ============================================================================
local function mask_token(token)
    if not token or #token == 0 then return "[Not Set]" end
    if #token <= 8 then return string.rep("*", #token) end
    return token:sub(1, 4) .. "..." .. token:sub(-4)
end

local function mask_url(url)
    if not url or #url == 0 then return "[Not Set]" end
    return url:gsub("^https?://", "")
end

function BalatroSync.get_settings_tab()
    return {
        label = "Cloud Sync",
        tab_definition_function = BalatroSync.create_sync_settings_ui,
        tab_definition_function_args = 'CloudSync'
    }
end

function BalatroSync.create_sync_settings_ui(tab)
    local dev_id = BalatroSync.config.device_id or "PC-PRIMARY"
    local cur_url = mask_url(BalatroSync.config.worker_url)
    local cur_tok = mask_token(BalatroSync.config.auth_token)

    local nodes = {
        -- Header
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                { n = G.UIT.T, config = { text = "BalatroSync Cloud Settings", scale = 0.52, colour = G.C.GOLD } }
            }
        },
        -- Live Status
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                { n = G.UIT.T, config = { text = "Status: " .. BalatroSync.status_text, scale = 0.42, colour = BalatroSync.status_color } }
            }
        },
        -- Server Info Card
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.04 },
            nodes = {
                { n = G.UIT.T, config = { text = "Worker: " .. cur_url, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
            }
        },
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.04 },
            nodes = {
                { n = G.UIT.T, config = { text = "Token: " .. cur_tok .. "  |  Device: " .. dev_id, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
            }
        },
        -- Quick Auth Setup Buttons (Copy / Paste from clipboard)
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.06 },
            nodes = {
                UIBox_button({
                    button = 'balatro_sync_copy_all',
                    label = {'[ Copy Setup Code ]'},
                    minw = 3.3,
                    minh = 0.75,
                    scale = 0.36,
                    colour = G.C.BLUE
                }),
                { n = G.UIT.C, config = { minw = 0.2, minh = 0.1 } },
                UIBox_button({
                    button = 'balatro_sync_paste_all',
                    label = {'[ Paste All ]'},
                    minw = 3.3,
                    minh = 0.75,
                    scale = 0.36,
                    colour = G.C.GOLD
                })
            }
        },
        -- Individual Paste Buttons Row
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                UIBox_button({
                    button = 'balatro_sync_paste_url',
                    label = {'[ Paste URL ]'},
                    minw = 3.3,
                    minh = 0.7,
                    scale = 0.36,
                    colour = G.C.BLUE
                }),
                { n = G.UIT.C, config = { minw = 0.2, minh = 0.1 } },
                UIBox_button({
                    button = 'balatro_sync_paste_token',
                    label = {'[ Paste Token ]'},
                    minw = 3.3,
                    minh = 0.7,
                    scale = 0.36,
                    colour = G.C.PURPLE
                })
            }
        },
        -- Device ID Cycler & Test Connection Row
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                UIBox_button({
                    button = 'balatro_sync_cycle_device',
                    label = {'[ Device: ' .. dev_id .. ' ]'},
                    minw = 3.3,
                    minh = 0.7,
                    scale = 0.36,
                    colour = G.C.SECONDARY
                }),
                { n = G.UIT.C, config = { minw = 0.2, minh = 0.1 } },
                UIBox_button({
                    button = 'balatro_sync_test',
                    label = {'[ Test Connection ]'},
                    minw = 3.3,
                    minh = 0.7,
                    scale = 0.36,
                    colour = G.C.GREEN
                })
            }
        },
        -- Manual Sync Actions Row
        {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.08 },
            nodes = {
                UIBox_button({
                    button = 'balatro_sync_download',
                    label = {'[ Download Save ]'},
                    minw = 3.3,
                    minh = 0.75,
                    scale = 0.38,
                    colour = G.C.BLUE
                }),
                { n = G.UIT.C, config = { minw = 0.2, minh = 0.1 } },
                UIBox_button({
                    button = 'balatro_sync_upload',
                    label = {'[ Upload Save ]'},
                    minw = 3.3,
                    minh = 0.75,
                    scale = 0.38,
                    colour = G.C.GREEN
                })
            }
        }
    }

    -- If active session conflict exists, show takeover button
    if BalatroSync.session_conflict then
        local conflict_text = string.format("Conflict: Active run on '%s'!", tostring(BalatroSync.session_conflict.remote_device))
        table.insert(nodes, {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                { n = G.UIT.T, config = { text = conflict_text, scale = 0.38, colour = G.C.RED } }
            }
        })
        table.insert(nodes, {
            n = G.UIT.R,
            config = { align = "cm", padding = 0.05 },
            nodes = {
                UIBox_button({
                    button = 'balatro_sync_takeover',
                    label = {'[ Force Take Over Session ]'},
                    minw = 6.8,
                    minh = 0.75,
                    scale = 0.38,
                    colour = G.C.ORANGE
                })
            }
        })
    end

    return {
        n = G.UIT.ROOT,
        config = { align = "cm", padding = 0.05, colour = G.C.CLEAR },
        nodes = nodes
    }
end

-- ============================================================================
-- 13. Service Button Callbacks (G.FUNCS)
-- ============================================================================
G.FUNCS = G.FUNCS or {}

local function extract_credentials(str)
    if not str then return nil, nil end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    local url, token = nil, nil

    -- 1. Check if JSON
    if str:sub(1,1) == "{" and str:sub(-1) == "}" then
        url = str:match('"worker_url"%s*:%s*"([^"]+)"')
        token = str:match('"auth_token"%s*:%s*"([^"]+)"')
        return url, token
    end

    -- 2. Check for URL with token in fragment or query
    local u = str:match("(https?://[%w%.%-_]+)")
    if u then
        url = u
        token = str:match("[#%?&]token=([%w%-_]+)") or str:match("#([%w%-_]+)")
    end

    -- 3. Standalone token
    if not url and #str >= 16 and #str <= 100 and not str:find("[%s/:]") then
        token = str
    end

    return url, token
end

G.FUNCS.balatro_sync_copy_all = function(e)
    local url = BalatroSync.config.worker_url or ""
    local token = BalatroSync.config.auth_token or ""
    local code = string.format("%s#%s", url, token)
    if love.system and love.system.setClipboardText then
        love.system.setClipboardText(code)
        BalatroSync.show_toast("[BalatroSync] Setup code copied! Ready to paste on other PC.", {0.3, 0.9, 0.4, 1.0})
    else
        BalatroSync.show_toast("[BalatroSync] Clipboard copy failed!", {1, 0.4, 0.4, 1.0})
    end
end

G.FUNCS.balatro_sync_paste_all = function(e)
    local clip = (love.system and love.system.getClipboardText and love.system.getClipboardText()) or ""
    clip = clip:gsub("^%s+", ""):gsub("%s+$", "")

    if #clip == 0 then
        BalatroSync.show_toast("[BalatroSync] Clipboard is empty!", {1, 0.4, 0.4, 1})
        return
    end

    local url, token = extract_credentials(clip)
    local updated = false

    if url then
        BalatroSync.config.worker_url = url
        updated = true
    end
    if token then
        BalatroSync.config.auth_token = token
        updated = true
    end

    if updated then
        BalatroSync.save_config()
        BalatroSync.show_toast("[BalatroSync] Credentials updated from clipboard!", {0.3, 0.9, 0.4, 1})
        BalatroSync.check_and_download((G.SETTINGS and G.SETTINGS.profile) or 1)
        if e and e.UIBox then e.UIBox:recalculate(true) end
    else
        BalatroSync.show_toast("[BalatroSync] No valid URL or token found in clipboard!", {1, 0.5, 0.2, 1})
    end
end

G.FUNCS.balatro_sync_paste_url = function(e)
    local clip = (love.system and love.system.getClipboardText and love.system.getClipboardText()) or ""
    local url = clip:match("(https?://[%w%.%-_]+)")
    if url then
        BalatroSync.config.worker_url = url
        BalatroSync.save_config()
        BalatroSync.show_toast("[BalatroSync] URL updated: " .. mask_url(url), {0.3, 0.9, 0.4, 1})
        if e and e.UIBox then e.UIBox:recalculate(true) end
    else
        BalatroSync.show_toast("[BalatroSync] No valid URL in clipboard!", {1, 0.4, 0.4, 1})
    end
end

G.FUNCS.balatro_sync_paste_token = function(e)
    local clip = (love.system and love.system.getClipboardText and love.system.getClipboardText()) or ""
    clip = clip:gsub("^%s+", ""):gsub("%s+$", "")
    if #clip >= 16 then
        BalatroSync.config.auth_token = clip
        BalatroSync.save_config()
        BalatroSync.show_toast("[BalatroSync] Token updated: " .. mask_token(clip), {0.3, 0.9, 0.4, 1})
        if e and e.UIBox then e.UIBox:recalculate(true) end
    else
        BalatroSync.show_toast("[BalatroSync] Token in clipboard is too short!", {1, 0.4, 0.4, 1})
    end
end

G.FUNCS.balatro_sync_cycle_device = function(e)
    local cur = BalatroSync.config.device_id or "PC-PRIMARY"
    local next_idx = 1
    for i, name in ipairs(device_presets) do
        if name == cur then
            next_idx = (i % #device_presets) + 1
            break
        end
    end
    BalatroSync.config.device_id = device_presets[next_idx]
    BalatroSync.save_config()
    BalatroSync.show_toast("[BalatroSync] Device ID set to: " .. BalatroSync.config.device_id, {0.3, 0.8, 1, 1})
    if e and e.UIBox then e.UIBox:recalculate(true) end
end

G.FUNCS.balatro_sync_test = function(e)
    BalatroSync.show_toast("[BalatroSync] Testing Cloudflare connection...", {0.3, 0.8, 1, 1})
    BalatroSync.check_and_download((G.SETTINGS and G.SETTINGS.profile) or 1)
end

G.FUNCS.balatro_sync_download = function(e)
    BalatroSync.show_toast("[BalatroSync] Starting download from cloud...", {0.3, 0.8, 1, 1})
    BalatroSync.force_download((G.SETTINGS and G.SETTINGS.profile) or 1)
end

G.FUNCS.balatro_sync_upload = function(e)
    BalatroSync.show_toast("[BalatroSync] Starting upload to cloud...", {0.3, 0.8, 1, 1})
    BalatroSync.dispatch_upload(false)
end

G.FUNCS.balatro_sync_takeover = function(e)
    BalatroSync.show_toast("[BalatroSync] Taking over session and uploading...", {1.0, 0.5, 0.1, 1})
    BalatroSync.session_conflict = nil
    BalatroSync.in_channel:push({
        type = "TAKEOVER",
        profile_id = (G.SETTINGS and G.SETTINGS.profile) or 1
    })
    BalatroSync.dispatch_upload(true)
end
