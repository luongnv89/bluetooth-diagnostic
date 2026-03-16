# Bluetooth Diagnostic

A comprehensive macOS Bluetooth diagnostic tool that analyzes connection quality, signal strength, congestion, and health for **all** paired Bluetooth devices.

Built to troubleshoot real-world issues like mouse input lag, audio dropouts, keyboard disconnects, and Bluetooth congestion — things that are hard to diagnose with macOS built-in tools alone.

## Features

- **All-device scanning** — diagnoses every paired Bluetooth device (connected and disconnected)
- **Signal strength (RSSI)** with visual bars and quality ratings
- **Battery monitoring** with low-battery warnings
- **Congestion analysis** — detects A2DP audio bandwidth competition
- **HID event monitoring** — checks for input drops, errors, and timeouts
- **Smart error filtering** — separates real Bluetooth errors from macOS noise (WirelessProximity false positives, benign battery polling, etc.)
- **Mouse-specific checks** — BLE latency, macOS MouseButtonMode, acceleration settings
- **Companion software audit** — Logi Options+ CPU/memory usage
- **Health scoring** — overall score with per-device health ratings
- **Summary table** — at-a-glance view of all devices with status, signal, battery, and health

## Requirements

- macOS (tested on macOS Sequoia / Apple Silicon)
- Python 3 (ships with macOS)
- No additional dependencies

## Installation

```bash
git clone https://github.com/luongnv89/bluetooth-diagnostic.git
cd bluetooth-diagnostic
chmod +x bt-diagnostic.sh
```

## Usage

### One-shot diagnostic

```bash
./bt-diagnostic.sh
```

Runs a full diagnostic and prints the report:

```
════════════════════════════════════════════════════════════
  BLUETOOTH DIAGNOSTIC — ALL DEVICES
  2026-03-16 23:17:23
════════════════════════════════════════════════════════════

[1] BLUETOOTH CONTROLLER
    Chipset:   BCM_4387
    Transport: PCIe
    ✓ PCIe transport (integrated, low latency)

[2] DEVICE-BY-DEVICE DIAGNOSTICS

  ── ⌨  Blue Element Keyboard  [CONNECTED]
    Protocol: Classic BT
    Signal:   N/A

  ── 🖱  MX Anywhere 3S  [CONNECTED]
    Protocol: BLE (Low Energy)
    ⚠ Mouse on BLE — typical latency 7.5–15ms per interval
    ✓ macOS MouseButtonMode: TwoButton (native)

  ── 🎧  AirPods Pro  [DISCONNECTED]
    Battery:  Case: 42%  Left: 100%  Right: 100%

[3] BLUETOOTH CONGESTION ANALYSIS
    Connected devices: 3 (BLE: 2, Classic: 1)
    ⚠ Moderate congestion — 3 devices

[4] HID & BLUETOOTH EVENTS (last 5 min)
    ✓ No HID errors or dropped events
    Bluetooth errors: 70 (excessive)
      → (8x) handlePeerDisconnectionCompleted: not found
    Benign BT warnings: 32 (battery polling, routing, etc.)
    Filtered noise: 258 (WirelessProximity 'error null' = success)

════════════════════════════════════════════════════════════
  ALL DEVICES SUMMARY
════════════════════════════════════════════════════════════

       Name                  Status         Type        RSSI  Battery           Health
  ──── ───────────────────── ────────────── ─────────── ───── ───────────────── ────────
  ⌨    Keyboard              ● Connected    Keyboard    --                      Healthy
  🖱   MX Anywhere 3S        ● Connected    Mouse       --                      Healthy
  🎧   AirPods Pro           ○ Disconnected Headphones  --    Case: 42%         —

════════════════════════════════════════════════════════════
  OVERALL HEALTH SCORE
════════════════════════════════════════════════════════════

  102 / 135  (75% — FAIR)

  [███████████████████████████████████████░░░░░░░░░░░░░]

════════════════════════════════════════════════════════════
  RECOMMENDATIONS
════════════════════════════════════════════════════════════

  1. Use a USB receiver (e.g. Logi Bolt) for your mouse
  2. High Bluetooth error rate (70 real errors in 5 min)
  3. Keep firmware updated for all devices
```

### Continuous monitoring

```bash
./bt-diagnostic.sh --watch
```

Re-runs the diagnostic every 10 seconds. Press `Ctrl+C` to stop. Useful for tracking signal changes while moving devices or toggling Bluetooth.

### Apply fixes

```bash
./bt-diagnostic.sh --fix
```

Applies safe, reversible fixes:
- Switches macOS `MouseButtonMode` from `OneButton` to `TwoButton` (removes software click-side detection overhead)
- Restarts Logi Options+ agent if CPU usage is abnormally high

## What it checks

| Check | What it detects |
|---|---|
| **Controller** | Chipset, firmware, transport (PCIe/USB) |
| **Per-device** | Type, address, firmware, protocol (BLE vs Classic), RSSI, battery |
| **Signal** | RSSI with visual bar — Excellent/Good/Fair/Weak/Poor |
| **Battery** | Level with color-coded warnings (red < 10%, yellow < 30%) |
| **Congestion** | Device count, A2DP audio bandwidth competition |
| **HID events** | Input errors, drops, timeouts, stalls |
| **BT errors** | Real errors vs benign noise (smart filtering) |
| **Mouse config** | ButtonMode, BLE latency, acceleration |
| **Software** | Logi Options+ process count and CPU usage |

## Error filtering

macOS generates hundreds of Bluetooth log entries that look like errors but are actually benign. This tool filters them into three categories:

| Category | Example | Impact |
|---|---|---|
| **Real errors** | `deviceDisconnected`, `SendSmartRoutingInformation failed` | Investigated and scored |
| **Benign warnings** | `battery fetch failed`, `BundleID does not exist` | Counted but not scored |
| **Noise** | `"with error (null)"` (WirelessProximity success messages) | Filtered out completely |

## Common issues this helps diagnose

- **Mouse input lag** — BLE latency, A2DP congestion, OneButton mode overhead
- **Audio dropouts** — too many devices competing for bandwidth
- **Keyboard disconnects** — weak signal, BT controller overload
- **General Bluetooth instability** — excessive errors, firmware issues

## License

MIT
