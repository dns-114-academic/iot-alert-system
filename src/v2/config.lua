-- =============================================================
-- config.lua
-- Shared configuration loader from NVS encrypted storage.
-- Run provisioning block ONCE via serial console, then comment it out.
-- Author: O. Denis
-- Platform: LuaRTOS on ESP32
-- =============================================================

-- ---- FIRST-TIME PROVISIONING (run once via serial, then comment out) ----
-- nvs.set("wifi",     "ssid",   "YOUR_SSID")
-- nvs.set("wifi",     "pass",   "YOUR_PASS")
-- nvs.set("telegram", "token",  "YOUR_BOT_TOKEN")
-- nvs.set("telegram", "chatid", "YOUR_CHAT_ID")
-- nvs.set("mqtt",     "broker", "192.168.1.100")   -- local broker IP
-- nvs.set("mqtt",     "port",   "1883")
-- nvs.set("node",     "id",     "1")               -- unique per node: 1, 2, 3...
-- -------------------------------------------------------------------------

local M = {}

function M.load()
    local cfg = {}

    -- WiFi
    cfg.wifi_ssid   = nvs.get("wifi", "ssid")
    cfg.wifi_pass   = nvs.get("wifi", "pass")

    -- Telegram
    cfg.tg_token    = nvs.get("telegram", "token")
    cfg.tg_chatid   = nvs.get("telegram", "chatid")

    -- MQTT
    cfg.mqtt_broker = nvs.get("mqtt", "broker")
    cfg.mqtt_port   = tonumber(nvs.get("mqtt", "port")) or 1883

    -- Node identity
    cfg.node_id     = tonumber(nvs.get("node", "id")) or 1

    -- Validate mandatory fields
    assert(cfg.wifi_ssid,   "NVS missing: wifi/ssid")
    assert(cfg.wifi_pass,   "NVS missing: wifi/pass")
    assert(cfg.tg_token,    "NVS missing: telegram/token")
    assert(cfg.tg_chatid,   "NVS missing: telegram/chatid")
    assert(cfg.mqtt_broker, "NVS missing: mqtt/broker")

    return cfg
end

return M
