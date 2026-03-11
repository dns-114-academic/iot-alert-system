# IoT Embedded Alert System

**Course project** | école d'ingénieurs — Nov. 2025–Jan. 2026 | Lua, ESP32, LuaRTOS

## Overview

Interrupt-driven vibration and shock detection system on ESP32 with multi-channel alerting: Telegram bot, OLED display and local buzzer.

## Features

### Detection
- **Hall sensor** — vibration and magnetic shock detection
- **Interrupt-driven** — real-time response without polling
- **Multi-level event classification** — low / medium / high intensity thresholds

### Alerting
- **Telegram Bot API** — remote push notifications with event level
- **OLED display** — local status and last event info
- **Buzzer fallback** — local alert if network unavailable

### Architecture
- LuaRTOS on ESP32
- Wi-Fi connectivity for Telegram API calls
- Event queue with debounce logic

## Stack

`Lua` · `LuaRTOS` · `ESP32` · `Telegram Bot API` · `I2C/OLED`

---

*Academic project — école d'ingénieurs*
