# IoT Embedded Alert System

> ESP32-based seismic detection system with real-time Telegram alerting via Hall-effect sensor.

## Directory Tree

```
iot-seismograph/
├── src/
│   ├── seismograph_debug.lua     # V1 — Single-thread polling (debug)
│   ├── seismograph.lua           # V1 — Multi-thread Hall sensor (production)
│   └── v2/
│       ├── config.lua            # V2 — NVS encrypted credential loader
│       ├── sensor_node.lua       # V2 — MPU-6050 node (flash on each ESP32)
│       └── aggregator.lua        # V2 — Consensus + Telegram + HTTP + SPIFFS
├── report/
│   ├── report_v1.pdf      # report — V1 PoC
│   └── report_v2.pdf      # report — V2 extended
└── README.md
```

## Implemented Components

### V1 (Hall sensor, single/dual thread)
| Module | File | Description |
|---|---|---|
| URL encoder | both v1 files | Percent-encoding for Telegram API |
| Hall sensor polling | `seismograph_debug.lua` | 50 ms loop, falling-edge count |
| Telegram sender (sync) | `seismograph_debug.lua` | Blocking HTTPS GET, pcall guard |
| Sensor thread | `seismograph.lua` | 30 ms polling, 3 s analysis window |
| Telegram thread | `seismograph.lua` | Async send, 30 s anti-spam |
| Alert classifier | both v1 files | 3-level: LOW / MODERATE / HIGH |

### V2 (MPU-6050, MQTT, consensus, dashboard, log)
| Module | File | Description |
|---|---|---|
| NVS credential loader | `config.lua` | Reads WiFi/Telegram/MQTT from encrypted NVS |
| MPU-6050 I2C driver | `sensor_node.lua` | Raw 6-byte accel read, signed conversion |
| RMS signal processor | `sensor_node.lua` | Gravity removal, tri-axis RMS over 3 s window |
| Alert classifier | `sensor_node.lua` | mg thresholds → LOW/MODERATE/HIGH |
| MQTT publisher | `sensor_node.lua` | JSON payload to `seismograph/node/{id}/status` |
| MQTT subscriber | `aggregator.lua` | Wildcard sub, manual JSON parse |
| N-of-M consensus | `aggregator.lua` | Quorum=2, 10 s staleness window |
| Telegram sender | `aggregator.lua` | Anti-spam 30 s, consensus-gated |
| HTTP dashboard | `aggregator.lua` | Auto-refresh HTML + `/api/status` JSON + `/log` |
| SPIFFS event log | `aggregator.lua` | Newline-JSON, 900 KB rotation, 20-entry RAM buffer |

## Requirements

- **Hardware**: ESP32 + KY-003 Hall sensor + oscillating magnet + (optional) 128×64 OLED
- **Firmware**: [LuaRTOS](https://github.com/whitecatboard/Lua-RTOS-ESP32)
- **External API**: Telegram Bot API (free, create bot via [@BotFather](https://t.me/botfather))
- No Python dependencies — pure Lua on-device

## Configuration

Before flashing, edit the top of either `.lua` file:

```lua
local TOKEN   = "YOUR_BOT_TOKEN_HERE"   -- from BotFather
local CHAT_ID = "YOUR_CHAT_ID_HERE"     -- your Telegram user/chat ID
net.wf.setup(net.wf.mode.STA, "YOUR_SSID", "YOUR_PASSWORD")
```

## How to Run

1. Flash LuaRTOS to your ESP32.
2. Upload `src/seismograph.lua` (production) via the LuaRTOS IDE or `wcc` CLI.
3. Open the serial monitor (115200 baud).
4. Observe:

```
Connecting to WiFi...
Connected!
=== SEISMOGRAPH ===
Telegram thread OK
Sensor thread OK
Monitoring active!
[SENSOR] Detection! Total: 1
[SENSOR] Alert LOW detected!
[TELEGRAM] Sending: SEISMIC ALERT Level LOW - 6 oscillations
[TELEGRAM] Sent!
[MAIN] Running...
```

Use `seismograph_debug.lua` for single-thread testing without thread concurrency.

## Alert Thresholds

| Oscillations / 3 s window | Level |
|---|---|
| 5 – 9 | LOW |
| 10 – 19 | MODERATE |
| ≥ 20 | HIGH |

Noise rejection: bursts > 40 oscillations/s (fans, machinery) and isolated peaks < 1 s are not confirmed.

## Design Notes

The system uses a mechanical pendulum with an attached magnet oscillating over a Hall-effect sensor. Each magnet pass induces a falling edge on the GPIO pin. Counting falling edges per time window approximates oscillation frequency, which correlates with seismic intensity. The dual-thread architecture in `seismograph.lua` decouples sensor polling (latency-sensitive, 30 ms) from network I/O (blocking, variable latency), preventing detection gaps during Telegram HTTP calls. Credentials are hardcoded for PoC purposes; production deployment should store them in encrypted EEPROM.

## References

- [KY-003 Hall sensor datasheet](https://docs.sunfounder.com/projects/umsk/fr/latest/01_components_basic/06-component_hall_sensor.html)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [LuaRTOS documentation](https://lua-rtos.readthedocs.io/)
