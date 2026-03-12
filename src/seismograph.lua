-- =============================================================
-- seismograph.lua
-- Seismic detection system - Multi-thread production version
-- Author: O. Denis
-- Platform: LuaRTOS on ESP32
-- =============================================================

-- Configuration
local HALL_PIN = pio.GPIO21

-- Telegram credentials (replace with your own)
local TOKEN = "YOUR_BOT_TOKEN_HERE"
local CHAT_ID = "YOUR_CHAT_ID_HERE"

-- Shared state between threads
local alert_level = nil
local alert_oscillations = 0
local send_in_progress = false

-- URL encoding function
function urlencode(str)
    if str then
        str = string.gsub(str, "([^%w])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

-- Telegram thread (runs continuously)
function telegram_thread()
    while true do
        -- Check if there is an alert to send
        if alert_level and not send_in_progress then
            send_in_progress = true

            local msg = "SEISMIC ALERT Level " .. alert_level .. " - " .. alert_oscillations .. " oscillations"
            local msg_encoded = urlencode(msg)
            local url = "https://api.telegram.org/bot" .. TOKEN .. "/sendMessage?chat_id=" .. CHAT_ID .. "&text=" .. msg_encoded

            print("[TELEGRAM] Sending: " .. msg)

            local ok, err = pcall(function()
                net.curl.get(url)
            end)

            if ok then
                print("[TELEGRAM] Sent!")
            else
                print("[TELEGRAM] Error: " .. tostring(err))
            end

            -- Reset shared state
            alert_level = nil
            alert_oscillations = 0
            send_in_progress = false

            -- Anti-spam pause (30 seconds)
            tmr.delayms(30000)
        else
            -- Light wait
            tmr.delayms(500)
        end
    end
end

-- Sensor thread (runs continuously)
function sensor_thread()
    local previous_state = 1
    local detections = 0
    local start_time = os.time()

    while true do
        local state = pio.pin.getval(HALL_PIN)

        -- Detect falling edge
        if state == 0 and previous_state == 1 then
            detections = detections + 1
            print("[SENSOR] Detection! Total: " .. detections)
        end

        previous_state = state

        -- Analysis every 3 seconds
        if os.time() - start_time >= 3 then
            if detections >= 5 and not send_in_progress then
                local level = "LOW"
                if detections >= 10 then level = "MODERATE" end
                if detections >= 20 then level = "HIGH" end

                print("[SENSOR] Alert " .. level .. " detected!")

                -- Pass alert to Telegram thread via shared variables
                alert_level = level
                alert_oscillations = detections
            end

            detections = 0
            start_time = os.time()
        end

        tmr.delayms(30)
    end
end

-- ============ MAIN PROGRAM ============

-- WiFi connection
print("Connecting to WiFi...")
net.wf.setup(net.wf.mode.STA, "YOUR_SSID", "YOUR_PASSWORD")
net.wf.start()
tmr.delayms(10000)
print("Connected!")

-- Sensor setup
pio.pin.setdir(pio.INPUT, HALL_PIN)
pio.pin.setpull(pio.PULLUP, HALL_PIN)

print("=== SEISMOGRAPH ===")

-- Start threads
thread.start(telegram_thread)
print("Telegram thread OK")

tmr.delayms(1000)

thread.start(sensor_thread)
print("Sensor thread OK")

print("Monitoring active!")

-- Main loop (watchdog)
while true do
    tmr.delayms(5000)
    print("[MAIN] Running...")
end
