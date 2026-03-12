-- =============================================================
-- sensor_node.lua
-- V2 Sensor node: MPU-6050 tri-axis accelerometer + MQTT publish.
-- Flash this on every detection ESP32 (node 1, 2, 3...).
-- Author: O. Denis
-- Platform: LuaRTOS on ESP32
-- =============================================================

local cfg = require("config").load()

-- ---- Constants -------------------------------------------------------
local MPU_ADDR    = 0x68      -- MPU-6050 I2C address (AD0 = GND)
local PWR_MGMT_1  = 0x6B      -- power management register
local ACCEL_REG   = 0x3B      -- first accel data register (6 bytes)
local ACCEL_SCALE = 16384.0   -- LSB/g for ±2g range

local SAMPLE_HZ   = 100       -- sampling rate (Hz)
local SAMPLE_MS   = 1000 / SAMPLE_HZ
local WINDOW_S    = 3         -- analysis window (seconds)
local WINDOW_N    = SAMPLE_HZ * WINDOW_S  -- samples per window

local THRESH_MIN_MG = 5       -- below = noise floor
local THRESH_MAX_HZ = 40      -- above = industrial (fans, motors)
local THRESH_LOW    = 5       -- mg RMS -> LOW
local THRESH_MOD    = 20      -- mg RMS -> MODERATE
local THRESH_HIGH   = 80      -- mg RMS -> HIGH

local MQTT_TOPIC  = "seismograph/node/" .. cfg.node_id .. "/status"
local MQTT_QOS    = 1

-- ---- I2C / MPU-6050 --------------------------------------------------
local i2c_id = i2c.setup(i2c.I2C0, pio.GPIO21, pio.GPIO22, i2c.FAST)

local function mpu_write(reg, val)
    i2c.start(i2c_id)
    i2c.address(i2c_id, MPU_ADDR, i2c.TRANSMITTER)
    i2c.write(i2c_id, reg, val)
    i2c.stop(i2c_id)
end

local function mpu_read_bytes(reg, n)
    -- Write register pointer
    i2c.start(i2c_id)
    i2c.address(i2c_id, MPU_ADDR, i2c.TRANSMITTER)
    i2c.write(i2c_id, reg)
    i2c.stop(i2c_id)
    -- Read n bytes
    i2c.start(i2c_id)
    i2c.address(i2c_id, MPU_ADDR, i2c.RECEIVER)
    local data = {i2c.read(i2c_id, n)}
    i2c.stop(i2c_id)
    return data
end

local function mpu_init()
    -- Wake up MPU-6050 (clear sleep bit)
    mpu_write(PWR_MGMT_1, 0x00)
    tmr.delayms(100)
    print("[MPU] Initialized")
end

-- Read raw accelerometer: returns ax, ay, az in g units
local function read_accel()
    local d = mpu_read_bytes(ACCEL_REG, 6)
    local function to_signed(hi, lo)
        local v = hi * 256 + lo
        if v >= 32768 then v = v - 65536 end
        return v
    end
    local ax = to_signed(d[1], d[2]) / ACCEL_SCALE
    local ay = to_signed(d[3], d[4]) / ACCEL_SCALE
    local az = to_signed(d[5], d[6]) / ACCEL_SCALE
    return ax, ay, az
end

-- ---- Signal processing -----------------------------------------------
-- Returns RMS amplitude in mg over one WINDOW_N sample burst
local function compute_rms()
    local sum_ax, sum_ay, sum_az = 0, 0, 0
    local buf = {}

    -- Pass 1: collect samples + compute mean (gravity removal)
    for i = 1, WINDOW_N do
        local ax, ay, az = read_accel()
        buf[i] = {ax, ay, az}
        sum_ax = sum_ax + ax
        sum_ay = sum_ay + ay
        sum_az = sum_az + az
        tmr.delayms(SAMPLE_MS)
    end

    local mean_ax = sum_ax / WINDOW_N
    local mean_ay = sum_ay / WINDOW_N
    local mean_az = sum_az / WINDOW_N

    -- Pass 2: compute RMS of detrended signal
    local sum_sq = 0
    for i = 1, WINDOW_N do
        local dx = buf[i][1] - mean_ax
        local dy = buf[i][2] - mean_ay
        local dz = buf[i][3] - mean_az
        sum_sq = sum_sq + dx*dx + dy*dy + dz*dz
    end

    -- Convert g to mg
    return math.sqrt(sum_sq / WINDOW_N) * 1000
end

-- Map RMS (mg) to alert level string
local function classify(rms_mg)
    if rms_mg < THRESH_MIN_MG then return "NOISE"    end
    if rms_mg < THRESH_LOW    then return "NOISE"    end
    if rms_mg < THRESH_MOD    then return "LOW"      end
    if rms_mg < THRESH_HIGH   then return "MODERATE" end
    return "HIGH"
end

-- ---- MQTT client -------------------------------------------------------
local mqtt_client = nil

local function mqtt_connect()
    mqtt_client = mqtt.client(
        "seismograph_node_" .. cfg.node_id,  -- client ID
        cfg.mqtt_broker,
        cfg.mqtt_port,
        false   -- no TLS (add for production)
    )
    local ok, err = pcall(function()
        mqtt_client:connect()
    end)
    if ok then
        print("[MQTT] Connected to " .. cfg.mqtt_broker)
    else
        print("[MQTT] Connection failed: " .. tostring(err))
        mqtt_client = nil
    end
end

local function mqtt_publish(payload)
    if not mqtt_client then
        mqtt_connect()
    end
    if mqtt_client then
        local ok, err = pcall(function()
            mqtt_client:publish(MQTT_TOPIC, payload, MQTT_QOS)
        end)
        if not ok then
            print("[MQTT] Publish failed: " .. tostring(err))
            mqtt_client = nil  -- force reconnect next time
        end
    end
end

-- ---- Sensor thread -----------------------------------------------------
function sensor_thread()
    mpu_init()
    print("[SENSOR] Thread started, node_id=" .. cfg.node_id)

    while true do
        local rms = compute_rms()
        local level = classify(rms)

        print(string.format("[SENSOR] RMS=%.1f mg -> %s", rms, level))

        -- Build JSON payload manually (no external json lib assumed)
        local payload = string.format(
            '{"node":%d,"level":"%s","rms":%.1f,"ts":%d}',
            cfg.node_id, level, rms, os.time()
        )

        mqtt_publish(payload)
    end
end

-- ---- Main --------------------------------------------------------------
print("Connecting to WiFi...")
net.wf.setup(net.wf.mode.STA, cfg.wifi_ssid, cfg.wifi_pass)
net.wf.start()
tmr.delayms(10000)
print("Connected!")

mqtt_connect()

print("=== SENSOR NODE " .. cfg.node_id .. " ===")
thread.start(sensor_thread)

-- Watchdog
while true do
    tmr.delayms(10000)
    print("[MAIN] Node " .. cfg.node_id .. " running...")
end
