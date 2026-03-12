-- =============================================================
-- seismograph_debug.lua
-- Seismic detection system - Debug / Single-thread version
-- Author: O. Denis
-- Platform: LuaRTOS on ESP32
-- =============================================================

-- Configuration
local HALL_PIN = pio.GPIO21
local detections = 0
local window = 2000  -- 2 seconds

-- Telegram credentials (replace with your own)
local TOKEN = "YOUR_BOT_TOKEN_HERE"
local CHAT_ID = "YOUR_CHAT_ID_HERE"

-- WiFi connection
net.wf.setup(net.wf.mode.STA, "YOUR_SSID", "YOUR_PASSWORD")
net.wf.start()
print("Connecting to WiFi...")
tmr.delayms(8000)
print("Connected!")

-- Setup KY-003 Hall sensor (polling instead of interrupt)
pio.pin.setdir(pio.INPUT, HALL_PIN)
pio.pin.setpull(pio.PULLUP, HALL_PIN)

-- Full URL encoding function
function url_encode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.])",
            function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

-- Telegram alert sender (fixed version)
function send_alert(message)
    -- Properly encode the message
    local msg_encoded = url_encode(message)
    local url = "https://api.telegram.org/bot" .. TOKEN ..
                "/sendMessage?chat_id=" .. CHAT_ID ..
                "&text=" .. msg_encoded

    print("Sending message...")

    -- Use pcall to capture errors
    local status, result, code = pcall(function()
        return net.curl.get(url)
    end)

    if status and code == 200 then
        print("Message sent!")
    else
        print("Send error: " .. tostring(code))
    end

    -- Important delay to prevent reboot
    tmr.delayms(3000)
end

print("=== SEISMOGRAPH ===")
print("Monitoring active...")

-- Detection variables
local previous_state = 1
local detections = 0
local start_time = os.time()

-- Main loop (polling instead of interrupt)
while true do
    -- Read current state
    local state = pio.pin.getval(HALL_PIN)

    -- Detect falling edge (magnet detected)
    if state == 0 and previous_state == 1 then
        detections = detections + 1
        print("Detection! Total: " .. detections)
    end

    previous_state = state

    -- Every 7 seconds, check for alerts
    if os.time() - start_time >= 7 then
        if detections >= 5 then
            local level = "LOW"
            if detections >= 10 then level = "MODERATE" end
            if detections >= 20 then level = "HIGH" end

            print("ALERT: " .. level)
            send_alert("SEISMIC ALERT Level: " .. level .. " Oscillations: " .. detections)
            console("Seismic alert")
        end
        start_time = os.time()
        detections = 0
    end

    tmr.delayms(50)
end
