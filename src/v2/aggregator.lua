-- =============================================================
-- aggregator.lua
-- V2 Aggregator node: MQTT subscribe, N-of-M consensus,
-- Telegram alert, local HTTP dashboard, SPIFFS event log.
-- Flash this on ONE dedicated ESP32 (the aggregator).
-- Author: O. Denis
-- Platform: LuaRTOS on ESP32
-- =============================================================

local cfg = require("config").load()

-- ---- Constants -------------------------------------------------------
local QUORUM       = 2         -- min nodes agreeing to trigger alert
local NODE_COUNT   = 3         -- total nodes in the network
local TIME_WINDOW  = 10        -- seconds: stale report threshold
local SPAM_DELAY   = 30000     -- ms: min delay between Telegram sends
local LOG_PATH     = "/spiffs/events.log"
local LOG_MAX_B    = 900 * 1024  -- 900 KB before rotation

local MQTT_SUB     = "seismograph/node/+/status"
local HTTP_PORT    = 80

-- Level ordering for max-level computation
local LEVEL_RANK = { NOISE = 0, LOW = 1, MODERATE = 2, HIGH = 3 }
local LEVEL_NAME = { [0]="NOISE", [1]="LOW", [2]="MODERATE", [3]="HIGH" }

-- ---- Shared state (between threads) ----------------------------------
local node_states    = {}   -- node_id(str) -> {level, rms, ts}
local last_alert_ts  = 0    -- timestamp of last Telegram send
local event_log_buf  = {}   -- last 20 events for dashboard

-- ---- URL encoding (for Telegram) -------------------------------------
local function urlencode(str)
    if str then
        str = string.gsub(str, "([^%w%-_%.~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

-- ---- SPIFFS event log ------------------------------------------------
local function spiffs_init()
    -- Ensure log file exists
    if not file.exists(LOG_PATH) then
        local f = io.open(LOG_PATH, "w")
        f:close()
        print("[LOG] Created " .. LOG_PATH)
    end
end

-- Drop oldest 20% of lines when file is too large
local function rotate_log()
    local lines = {}
    local f = io.open(LOG_PATH, "r")
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()

    local keep_from = math.floor(#lines * 0.20) + 1
    local f2 = io.open(LOG_PATH, "w")
    for i = keep_from, #lines do
        f2:write(lines[i] .. "\n")
    end
    f2:close()
    print("[LOG] Rotated: dropped " .. (keep_from - 1) .. " old entries")
end

local function log_event(level, rms, node_count, duration_s)
    local entry = string.format(
        '{"ts":%d,"level":"%s","rms":%.1f,"nodes":%d,"duration_s":%d}',
        os.time(), level, rms, node_count, duration_s
    )

    local f = io.open(LOG_PATH, "a")
    f:write(entry .. "\n")
    f:close()

    -- Keep in-memory ring buffer (last 20 events for dashboard)
    table.insert(event_log_buf, entry)
    if #event_log_buf > 20 then
        table.remove(event_log_buf, 1)
    end

    -- Check rotation
    local size = file.size(LOG_PATH)
    if size > LOG_MAX_B then
        rotate_log()
    end

    print("[LOG] Event written: " .. entry)
end

-- ---- Telegram sender -------------------------------------------------
local function send_telegram(level, node_count)
    local now = os.time()
    -- Anti-spam: enforce minimum delay
    if (now - last_alert_ts) * 1000 < SPAM_DELAY then
        print("[TELEGRAM] Skipped (anti-spam)")
        return
    end

    local msg = string.format(
        "SEISMIC ALERT [%s] confirmed by %d/%d nodes at %s",
        level, node_count, NODE_COUNT, os.date("%H:%M:%S", now)
    )
    local url = "https://api.telegram.org/bot" .. cfg.tg_token ..
                "/sendMessage?chat_id=" .. cfg.tg_chatid ..
                "&text=" .. urlencode(msg)

    print("[TELEGRAM] Sending: " .. msg)
    local ok, err = pcall(function()
        net.curl.get(url)
    end)
    if ok then
        print("[TELEGRAM] Sent!")
        last_alert_ts = now
    else
        print("[TELEGRAM] Error: " .. tostring(err))
    end
end

-- ---- Consensus evaluation --------------------------------------------
local function evaluate_consensus()
    local now        = os.time()
    local alert_count = 0
    local max_rank   = 0
    local sum_rms    = 0.0
    local rms_count  = 0

    for id, state in pairs(node_states) do
        if now - state.ts <= TIME_WINDOW then
            local rank = LEVEL_RANK[state.level] or 0
            if rank > 0 then  -- not NOISE
                alert_count = alert_count + 1
                if rank > max_rank then max_rank = rank end
                sum_rms = sum_rms + state.rms
                rms_count = rms_count + 1
            end
        end
    end

    if alert_count >= QUORUM then
        local level    = LEVEL_NAME[max_rank]
        local avg_rms  = rms_count > 0 and (sum_rms / rms_count) or 0.0

        print(string.format("[CONSENSUS] ALERT %s from %d nodes (avg RMS=%.1f mg)",
              level, alert_count, avg_rms))

        send_telegram(level, alert_count)
        log_event(level, avg_rms, alert_count, TIME_WINDOW)
    end
end

-- ---- MQTT subscriber thread ------------------------------------------
function mqtt_thread()
    local client = mqtt.client(
        "seismograph_aggregator",
        cfg.mqtt_broker,
        cfg.mqtt_port,
        false
    )

    -- Connect with retry
    while true do
        local ok, err = pcall(function() client:connect() end)
        if ok then
            print("[MQTT] Aggregator connected")
            break
        end
        print("[MQTT] Connect failed, retrying in 5s: " .. tostring(err))
        tmr.delayms(5000)
    end

    -- Subscribe to all nodes
    client:subscribe(MQTT_SUB, 1)
    print("[MQTT] Subscribed to " .. MQTT_SUB)

    -- Message callback
    client:on("message", function(topic, payload)
        print("[MQTT] Received: " .. topic .. " -> " .. payload)

        -- Extract node_id from topic: seismograph/node/{id}/status
        local node_id = string.match(topic, "node/(%d+)/")
        if not node_id then return end

        -- Parse JSON manually (basic, no nested structures)
        local level = string.match(payload, '"level"%s*:%s*"([^"]+)"')
        local rms   = tonumber(string.match(payload, '"rms"%s*:%s*([%d%.]+)'))
        local ts    = tonumber(string.match(payload, '"ts"%s*:%s*(%d+)'))

        if level and rms and ts then
            node_states[node_id] = { level = level, rms = rms, ts = ts }
            print(string.format("[STATE] Node %s: %s (%.1f mg)", node_id, level, rms))
            evaluate_consensus()
        else
            print("[MQTT] Malformed payload, skipped")
        end
    end)

    -- Keep thread alive (callback-driven)
    while true do
        tmr.delayms(1000)
    end
end

-- ---- HTTP dashboard thread -------------------------------------------
-- Generates a minimal HTML page + SSE endpoint

local function build_dashboard_html()
    local rows = ""
    for id, s in pairs(node_states) do
        local age = os.time() - s.ts
        local color = "green"
        if s.level == "HIGH"     then color = "red"
        elseif s.level == "MODERATE" then color = "orange"
        elseif s.level == "LOW"  then color = "gold"
        elseif age > TIME_WINDOW then color = "gray"
        end
        rows = rows .. string.format(
            '<tr><td>Node %s</td><td style="color:%s"><b>%s</b></td>'..
            '<td>%.1f mg</td><td>%ds ago</td></tr>',
            id, color, s.level, s.rms, age
        )
    end

    local log_rows = ""
    for i = #event_log_buf, math.max(1, #event_log_buf - 9), -1 do
        log_rows = log_rows .. "<tr><td><code>" .. event_log_buf[i] .. "</code></td></tr>"
    end

    return string.format([[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="3">
<title>Seismograph Dashboard</title>
<style>
  body { font-family: monospace; background:#111; color:#eee; padding:1em; }
  h1   { color:#4af; }
  table{ border-collapse:collapse; width:100%%; margin-bottom:1.5em; }
  td,th{ border:1px solid #444; padding:6px 12px; }
  th   { background:#222; color:#aaa; }
</style>
</head>
<body>
<h1>IoT Seismograph — Live Dashboard</h1>
<p>Updated: %s | Quorum: %d/%d nodes</p>
<h2>Node Status</h2>
<table><tr><th>Node</th><th>Level</th><th>RMS</th><th>Age</th></tr>
%s
</table>
<h2>Last Events</h2>
<table><tr><th>JSON Log Entry</th></tr>
%s
</table>
</body></html>
]], os.date("%H:%M:%S"), QUORUM, NODE_COUNT, rows, log_rows)
end

function http_thread()
    local server = net.service.http.new()

    server:route("/", function(req, res)
        local html = build_dashboard_html()
        res:send(200, "text/html", html)
    end)

    -- Raw JSON API endpoint (for external monitoring)
    server:route("/api/status", function(req, res)
        local payload = '{"nodes":{'
        local first = true
        for id, s in pairs(node_states) do
            if not first then payload = payload .. "," end
            payload = payload .. string.format(
                '"%s":{"level":"%s","rms":%.1f,"ts":%d}',
                id, s.level, s.rms, s.ts
            )
            first = false
        end
        payload = payload .. '},"last_events":['
        for i, e in ipairs(event_log_buf) do
            if i > 1 then payload = payload .. "," end
            payload = payload .. e
        end
        payload = payload .. ']}'
        res:send(200, "application/json", payload)
    end)

    -- Log download endpoint
    server:route("/log", function(req, res)
        if file.exists(LOG_PATH) then
            local f   = io.open(LOG_PATH, "r")
            local content = f:read("*a")
            f:close()
            res:send(200, "text/plain", content)
        else
            res:send(404, "text/plain", "No log file found")
        end
    end)

    print("[HTTP] Dashboard listening on port " .. HTTP_PORT)
    server:listen(HTTP_PORT)
end

-- ---- Main --------------------------------------------------------------
print("Connecting to WiFi...")
net.wf.setup(net.wf.mode.STA, cfg.wifi_ssid, cfg.wifi_pass)
net.wf.start()
tmr.delayms(10000)
print("Connected! IP: " .. net.wf.ip())

spiffs_init()

print("=== AGGREGATOR NODE ===")

thread.start(mqtt_thread)
print("[MAIN] MQTT thread started")

tmr.delayms(2000)

thread.start(http_thread)
print("[MAIN] HTTP thread started")

-- Watchdog + periodic status print
while true do
    tmr.delayms(15000)
    print(string.format("[MAIN] Running | nodes seen: %d | log entries: %d",
          #node_states, #event_log_buf))
end
