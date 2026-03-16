#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  bt-diagnostic.sh — Bluetooth Devices Connection Quality Check
#  Usage: ./bt-diagnostic.sh [--watch] [--fix]
#    --watch   Continuous monitoring mode (every 10s, Ctrl+C to stop)
#    --fix     Apply recommended macOS mouse config fixes
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Colors
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
MAG='\033[0;35m'
BLD='\033[1m'
DIM='\033[2m'
RST='\033[0m'

WATCH_MODE=false
FIX_MODE=false
WATCH_INTERVAL=10

for arg in "$@"; do
    case "$arg" in
        --watch) WATCH_MODE=true ;;
        --fix)   FIX_MODE=true ;;
        --help|-h)
            echo "Usage: $0 [--watch] [--fix]"
            echo "  --watch   Continuous monitoring (every ${WATCH_INTERVAL}s)"
            echo "  --fix     Apply recommended mouse config fixes"
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────

header() {
    printf "\n${BLD}${CYN}[%s] %s${RST}\n" "$1" "$2"
}

subheader() {
    printf "\n  ${BLD}${MAG}── %s${RST}\n" "$1"
}

ok()   { printf "    ${GRN}✓${RST} %s\n" "$1"; }
warn() { printf "    ${YEL}⚠${RST} %s\n" "$1"; }
crit() { printf "    ${RED}✖${RST} %s\n" "$1"; }
info() { printf "    ${DIM}%s${RST}\n" "$1"; }

score_total=0
score_max=0

score() {
    local points=$1 max=$2
    score_total=$((score_total + points))
    score_max=$((score_max + max))
}

# Global data
BT_JSON=""
DEVICE_SUMMARIES=""

# ─────────────────────────────────────────────────────────────
#  Collect all BT device data via Python (single call)
# ─────────────────────────────────────────────────────────────

collect_device_data() {
    BT_JSON=$(system_profiler SPBluetoothDataType -json 2>/dev/null || echo "{}")
}

# Parse all devices into a structured list
# Output format per line: STATUS|NAME|TYPE|ADDRESS|SERVICES|FIRMWARE|RSSI|BATTERY|VENDOR
parse_all_devices() {
    echo "$BT_JSON" | python3 -c "
import json, sys

d = json.load(sys.stdin)
bt = d.get('SPBluetoothDataType', [{}])[0]

def parse_devices(devices, status):
    for dev in devices:
        if isinstance(dev, dict):
            for name, info in dev.items():
                dtype = info.get('device_minorType', 'Unknown')
                addr = info.get('device_address', 'unknown')
                svc = info.get('device_services', '')
                fw = info.get('device_firmwareVersion', '')
                rssi = info.get('device_rssi', '')
                vendor = info.get('device_vendorID', '')

                # Collect battery info
                batt_parts = []
                for k, v in info.items():
                    kl = k.lower()
                    if 'battery' in kl and 'level' in kl:
                        label = k.replace('device_', '').replace('BatteryLevel', '').replace('batteryLevel', '').replace('_', ' ').strip()
                        if not label:
                            label = 'Battery'
                        batt_parts.append(f'{label}: {v}')
                batt = ', '.join(batt_parts) if batt_parts else ''

                print(f'{status}|{name}|{dtype}|{addr}|{svc}|{fw}|{rssi}|{batt}|{vendor}')

parse_devices(bt.get('device_connected', []), 'Connected')
parse_devices(bt.get('device_not_connected', []), 'Not Connected')
" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
#  1. Bluetooth controller info
# ─────────────────────────────────────────────────────────────

check_controller() {
    header "1" "BLUETOOTH CONTROLLER"

    echo "$BT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bt = d.get('SPBluetoothDataType', [{}])[0]
ctrl = bt.get('controller_properties', bt)
print(ctrl.get('controller_chipset', 'unknown'))
print(ctrl.get('controller_firmwareVersion', 'unknown'))
print(ctrl.get('controller_transport', 'unknown'))
print(ctrl.get('controller_address', 'unknown'))
" 2>/dev/null | {
        read -r chipset || chipset="unknown"
        read -r fw || fw="unknown"
        read -r transport || transport="unknown"
        read -r addr || addr="unknown"

        # Fallback to text parsing if JSON keys differ
        if [[ "$chipset" == "unknown" ]]; then
            local bt_text
            bt_text=$(system_profiler SPBluetoothDataType 2>/dev/null)
            chipset=$(echo "$bt_text" | grep "Chipset:" | awk -F': ' '{print $2}' | xargs)
            fw=$(echo "$bt_text" | grep "Firmware Version:" | head -1 | awk -F': ' '{print $2}' | xargs)
            transport=$(echo "$bt_text" | grep "Transport:" | awk -F': ' '{print $2}' | xargs)
            addr=$(echo "$bt_text" | grep -m1 "Address:" | awk -F': ' '{print $2}' | xargs)
        fi

        info "Address:   ${addr:-unknown}"
        info "Chipset:   ${chipset:-unknown}"
        info "Firmware:  ${fw:-unknown}"
        info "Transport: ${transport:-unknown}"

        if [[ "${transport:-}" == "PCIe" ]]; then
            ok "PCIe transport (integrated, low latency)"
            score 10 10
        elif [[ "${transport:-}" == "USB" ]]; then
            ok "USB transport"
            score 8 10
        else
            warn "Unknown transport: ${transport:-}"
            score 5 10
        fi
    }
}

# ─────────────────────────────────────────────────────────────
#  2. Per-device diagnostics
# ─────────────────────────────────────────────────────────────

# Icon for device type
device_icon() {
    case "$1" in
        Mouse)       echo "🖱" ;;
        Keyboard)    echo "⌨" ;;
        Headphones)  echo "🎧" ;;
        Speaker)     echo "🔊" ;;
        Phone|Smartphone) echo "📱" ;;
        *)           echo "📡" ;;
    esac
}

# Evaluate RSSI quality
rssi_quality() {
    local rssi=$1
    if [[ -z "$rssi" || "$rssi" == "N/A" ]]; then
        echo "N/A"
        return
    fi
    if (( rssi > -50 )); then echo "Excellent"
    elif (( rssi > -60 )); then echo "Good"
    elif (( rssi > -70 )); then echo "Fair"
    elif (( rssi > -80 )); then echo "Weak"
    else echo "Poor"
    fi
}

# RSSI bar
rssi_bar() {
    local rssi=$1
    if [[ -z "$rssi" || "$rssi" == "N/A" ]]; then
        printf "${DIM}[no signal data]${RST}"
        return
    fi
    local bar_len=$(( (100 + rssi) / 2 ))
    [[ $bar_len -lt 1 ]] && bar_len=1
    [[ $bar_len -gt 30 ]] && bar_len=30

    local color="$RED"
    if (( rssi > -50 )); then color="$GRN"
    elif (( rssi > -60 )); then color="$GRN"
    elif (( rssi > -70 )); then color="$YEL"
    elif (( rssi > -80 )); then color="$YEL"
    fi

    printf "["
    for ((i=0; i<bar_len; i++)); do printf "${color}█${RST}"; done
    for ((i=bar_len; i<30; i++)); do printf "${DIM}░${RST}"; done
    printf "]"
}

diagnose_device() {
    # Args: STATUS|NAME|TYPE|ADDRESS|SERVICES|FIRMWARE|RSSI|BATTERY|VENDOR
    local status="$1" name="$2" dtype="$3" addr="$4" svc="$5" fw="$6" rssi="$7" battery="$8" vendor="$9"
    local icon
    icon=$(device_icon "$dtype")

    local status_color="$GRN"
    local status_label="CONNECTED"
    if [[ "$status" != "Connected" ]]; then
        status_color="$DIM"
        status_label="DISCONNECTED"
    fi

    subheader "${icon}  ${name}  [${status_color}${status_label}${RST}${BLD}${MAG}]"

    info "Type:     ${dtype}"
    info "Address:  ${addr}"
    if [[ -n "$fw" ]]; then
        info "Firmware: ${fw}"
    fi
    if [[ -n "$vendor" ]]; then
        info "Vendor:   ${vendor}"
    fi

    # Protocol
    local protocol="Classic BT"
    if echo "$svc" | grep -q "BLE"; then
        protocol="BLE (Low Energy)"
    fi
    if [[ -n "$svc" && "$svc" != "unknown" ]]; then
        info "Services: ${svc}"
    fi
    info "Protocol: ${protocol}"

    # RSSI / Signal
    if [[ -n "$rssi" ]]; then
        local quality
        quality=$(rssi_quality "$rssi")
        printf "    Signal:   %s dBm (%s) " "$rssi" "$quality"
        rssi_bar "$rssi"
        printf "\n"

        if [[ "$status" == "Connected" ]]; then
            case "$quality" in
                Excellent|Good) score 10 10 ;;
                Fair)           score 5 10; warn "Signal fair — may experience intermittent issues" ;;
                Weak)           score 2 10; crit "Weak signal — likely causing latency/drops" ;;
                Poor)           score 0 10; crit "Very weak signal — high packet loss" ;;
            esac
        fi
    else
        if [[ "$status" == "Connected" ]]; then
            if echo "$svc" | grep -q "BLE"; then
                info "Signal:   N/A (BLE devices don't expose RSSI on macOS)"
                score 5 10
            else
                info "Signal:   N/A"
                score 5 10
            fi
        fi
    fi

    # Battery
    if [[ -n "$battery" ]]; then
        printf "    Battery:  "
        # Parse each battery component
        IFS=',' read -ra batt_parts <<< "$battery"
        for part in "${batt_parts[@]}"; do
            part=$(echo "$part" | xargs)
            local level
            level=$(echo "$part" | grep -oE '[0-9]+' | head -1)
            if [[ -n "$level" ]]; then
                local batt_color="$GRN"
                if (( level <= 10 )); then
                    batt_color="$RED"
                elif (( level <= 30 )); then
                    batt_color="$YEL"
                fi
                printf "${batt_color}%s${RST}  " "$part"
            else
                printf "%s  " "$part"
            fi
        done
        printf "\n"

        # Score battery for connected devices
        if [[ "$status" == "Connected" ]]; then
            local main_level
            main_level=$(echo "$battery" | grep -oE '[0-9]+' | head -1)
            if [[ -n "$main_level" ]]; then
                if (( main_level <= 10 )); then
                    crit "Battery critically low — may cause erratic behavior"
                    score 0 5
                elif (( main_level <= 20 )); then
                    warn "Battery low — charge soon"
                    score 3 5
                else
                    score 5 5
                fi
            fi
        fi
    fi

    # Device-specific checks for connected devices
    if [[ "$status" == "Connected" ]]; then

        # Audio device checks
        if echo "$svc" | grep -q "A2DP"; then
            warn "A2DP audio streaming — consumes significant BT bandwidth"
            info "This can cause latency for other BT devices (mouse, keyboard)"
            score 3 10
        else
            score 10 10
        fi

        # BLE latency check for mice
        if [[ "$dtype" == "Mouse" ]] && echo "$svc" | grep -q "BLE"; then
            warn "Mouse on BLE — typical latency 7.5–15ms per interval"
            info "A USB receiver (e.g. Logi Bolt) provides ~1ms polling"
            score 5 10
        elif [[ "$dtype" == "Mouse" ]]; then
            ok "Mouse on Classic BT HID — good latency"
            score 8 10
        fi

        # Mouse config check
        if [[ "$dtype" == "Mouse" ]]; then
            local button_mode
            button_mode=$(defaults read com.apple.AppleMultitouchMouse MouseButtonMode 2>/dev/null || echo "not set")
            if [[ "$button_mode" == "OneButton" ]]; then
                crit "macOS MouseButtonMode: OneButton (adds click detection overhead)"
                info "Fix: Run $0 --fix to switch to TwoButton"
                score 0 10
            elif [[ "$button_mode" == "TwoButton" ]]; then
                ok "macOS MouseButtonMode: TwoButton (native)"
                score 10 10
            else
                info "macOS MouseButtonMode: ${button_mode}"
                score 7 10
            fi
        fi

    fi

    # Build summary line for the final table
    local health="—"
    if [[ "$status" == "Connected" ]]; then
        # Compute a mini health based on what we know
        local issues=0
        if echo "$svc" | grep -q "A2DP"; then ((issues++)) || true; fi
        if [[ -n "$rssi" ]] && (( rssi < -70 )); then ((issues++)) || true; fi
        if [[ -n "$battery" ]]; then
            local bl
            bl=$(echo "$battery" | grep -oE '[0-9]+' | head -1)
            if [[ -n "$bl" ]] && (( bl <= 15 )); then ((issues++)) || true; fi
        fi
        if (( issues == 0 )); then health="${GRN}Healthy${RST}"
        elif (( issues == 1 )); then health="${YEL}Fair${RST}"
        else health="${RED}Degraded${RST}"
        fi
    fi

    # Append to global summary (escaped for later printing)
    local batt_short=""
    if [[ -n "$battery" ]]; then
        batt_short=$(echo "$battery" | head -c 35)
    fi
    local rssi_short="${rssi:---}"
    DEVICE_SUMMARIES+="${icon}|${name}|${status_label}|${dtype}|${rssi_short}|${batt_short}|${health}|${protocol}\n"
}

# ─────────────────────────────────────────────────────────────
#  3. System-wide checks
# ─────────────────────────────────────────────────────────────

check_congestion() {
    header "3" "BLUETOOTH CONGESTION ANALYSIS"

    local connected_count=0
    local a2dp_count=0
    local ble_count=0
    local classic_count=0

    while IFS='|' read -r status name dtype addr svc fw rssi battery vendor; do
        [[ "$status" != "Connected" ]] && continue
        ((connected_count++)) || true
        if echo "$svc" | grep -q "A2DP"; then ((a2dp_count++)) || true; fi
        if echo "$svc" | grep -q "BLE"; then ((ble_count++)) || true; fi
        if echo "$svc" | grep -q "HID\|HFP\|ACL" && ! echo "$svc" | grep -q "BLE"; then ((classic_count++)) || true; fi
    done <<< "$(parse_all_devices)"

    info "Connected devices: ${connected_count} (BLE: ${ble_count}, Classic: ${classic_count})"

    if (( a2dp_count > 0 )); then
        crit "A2DP audio active on ${a2dp_count} device(s) — major bandwidth consumer"
        score 0 20
    elif (( connected_count >= 5 )); then
        crit "Very high congestion — ${connected_count} devices on one controller"
        score 2 20
    elif (( connected_count >= 4 )); then
        warn "High congestion — ${connected_count} devices active"
        score 8 20
    elif (( connected_count >= 3 )); then
        warn "Moderate congestion — ${connected_count} devices"
        score 12 20
    elif (( connected_count >= 2 )); then
        ok "Low congestion — ${connected_count} devices"
        score 16 20
    else
        ok "Minimal load — ${connected_count} device"
        score 20 20
    fi
}

check_hid_events() {
    header "4" "HID & BLUETOOTH EVENTS (last 5 min)"

    # Use /usr/bin/log to avoid zsh builtin 'log' conflict
    local LOG=/usr/bin/log

    local hid_output
    hid_output=$($LOG show --predicate 'subsystem == "com.apple.HID"' --last 5m --style compact 2>/dev/null || true)

    local total_events error_events
    total_events=$(echo "$hid_output" | grep -c '.' 2>/dev/null | tr -d '[:space:]' || echo "0")
    error_events=$(echo "$hid_output" | grep -ic 'error\|timeout\|drop\|fail\|stall' 2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$total_events" ]] && total_events=0
    [[ -z "$error_events" ]] && error_events=0

    info "HID events: ${total_events}"

    if (( error_events > 0 )); then
        crit "HID errors/drops: ${error_events}"
        echo "$hid_output" | grep -i 'error\|timeout\|drop\|fail\|stall' | head -3 | while read -r line; do
            info "  → ${line:0:120}"
        done
        score 0 10
    else
        ok "No HID errors or dropped events"
        score 10 10
    fi

    # Bluetooth error analysis with false-positive filtering
    # Exclude:
    #   "with error (null)"  — benign WirelessProximity success messages
    #   "BundleID does not exist" — known macOS cosmetic bug
    #   "battery fetch failed" — normal for 3rd-party devices without IORegistry battery
    #   "ALREADY_NOT_DISCOVERABLE" — benign BLE advertising race condition
    local bt_log
    bt_log=$($LOG show --predicate 'subsystem == "com.apple.bluetooth"' --last 5m --style compact 2>/dev/null || true)

    local bt_total bt_real_errors bt_warnings
    bt_total=$(echo "$bt_log" | grep -c '.' 2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$bt_total" ]] && bt_total=0

    # Real errors: grep for error keywords, then exclude known false positives
    bt_real_errors=$(echo "$bt_log" \
        | grep -i 'error\|disconnect\|fail\|timeout' \
        | grep -iv 'error (null)\|BundleID does not exist\|battery fetch failed\|ALREADY_NOT_DISCOVERABLE\|Disconnected with no nearby' \
        2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    [[ -z "$bt_real_errors" ]] && bt_real_errors=0

    # Count the benign ones separately for info
    bt_warnings=$(echo "$bt_log" \
        | grep -ic 'battery fetch failed\|BundleID does not exist\|Disconnected with no nearby\|ALREADY_NOT_DISCOVERABLE' \
        2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$bt_warnings" ]] && bt_warnings=0

    local bt_false_positives
    bt_false_positives=$(echo "$bt_log" \
        | grep -ic 'with error (null)' \
        2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$bt_false_positives" ]] && bt_false_positives=0

    info "BT log entries: ${bt_total}"

    if (( bt_real_errors > 20 )); then
        crit "Bluetooth errors in last 5 min: ${bt_real_errors} (excessive)"
        # Show top error types
        echo "$bt_log" \
            | grep -i 'error\|disconnect\|fail\|timeout' \
            | grep -iv 'error (null)\|BundleID does not exist\|battery fetch failed\|ALREADY_NOT_DISCOVERABLE\|Disconnected with no nearby' \
            | sed 's/.*\] //' | sort | uniq -c | sort -rn | head -3 | while read -r cnt msg; do
                info "  → (${cnt}x) ${msg:0:90}"
            done
        score 0 10
    elif (( bt_real_errors > 5 )); then
        warn "Bluetooth errors in last 5 min: ${bt_real_errors}"
        echo "$bt_log" \
            | grep -i 'error\|disconnect\|fail\|timeout' \
            | grep -iv 'error (null)\|BundleID does not exist\|battery fetch failed\|ALREADY_NOT_DISCOVERABLE\|Disconnected with no nearby' \
            | sed 's/.*\] //' | sort | uniq -c | sort -rn | head -3 | while read -r cnt msg; do
                info "  → (${cnt}x) ${msg:0:90}"
            done
        score 5 10
    elif (( bt_real_errors > 0 )); then
        warn "Bluetooth errors in last 5 min: ${bt_real_errors} (minor)"
        score 8 10
    else
        ok "No Bluetooth errors"
        score 10 10
    fi

    if (( bt_warnings > 0 )); then
        info "Benign BT warnings: ${bt_warnings} (battery polling, routing, etc.)"
    fi
    if (( bt_false_positives > 0 )); then
        info "Filtered noise: ${bt_false_positives} (WirelessProximity 'error null' = success)"
    fi
}

check_logi_software() {
    header "5" "COMPANION SOFTWARE"

    # Logi Options+
    local logi_procs
    logi_procs=$(ps aux 2>/dev/null | grep -i "logioptionsplus\|logi_ai" | grep -v grep || true)

    if [[ -n "$logi_procs" ]]; then
        local proc_count
        proc_count=$(echo "$logi_procs" | wc -l | xargs)
        info "Logi Options+ processes: ${proc_count}"

        echo "$logi_procs" | while read -r line; do
            local pname cpu mem
            pname=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's|.*/||' | cut -c1-50)
            cpu=$(echo "$line" | awk '{print $3}')
            mem=$(echo "$line" | awk '{print $4}')
            info "  → ${pname} (CPU: ${cpu}% | MEM: ${mem}%)"
        done

        local total_cpu
        total_cpu=$(echo "$logi_procs" | awk '{sum+=$3} END {printf "%.1f", sum}')
        if (( $(echo "$total_cpu > 5.0" | bc -l 2>/dev/null || echo 0) )); then
            warn "Logi Options+ total CPU: ${total_cpu}% — may add input latency"
            score 5 10
        else
            ok "Logi Options+ CPU normal (${total_cpu}%)"
            score 10 10
        fi
    else
        info "Logi Options+ not running"
        score 10 10
    fi

    # Check for other BT-related daemons
    local bt_procs
    bt_procs=$(ps aux 2>/dev/null | grep -iE "bluetooth|blue.element|karabiner" | grep -v grep | grep -v "bt-diagnostic" || true)
    if [[ -n "$bt_procs" ]]; then
        local bp_count
        bp_count=$(echo "$bt_procs" | wc -l | xargs)
        info "Other BT-related processes: ${bp_count}"
    fi
}

# ─────────────────────────────────────────────────────────────
#  Score bar & overall summary
# ─────────────────────────────────────────────────────────────

print_score() {
    echo ""
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    printf "${BLD}  OVERALL HEALTH SCORE${RST}\n"
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    echo ""

    local pct=0
    if (( score_max > 0 )); then
        pct=$(( (score_total * 100) / score_max ))
    fi

    local bar_len=$(( pct / 2 ))
    [[ $bar_len -lt 0 ]] && bar_len=0
    [[ $bar_len -gt 50 ]] && bar_len=50

    local color="$RED"
    local grade="POOR"
    if (( pct >= 80 )); then color="$GRN"; grade="GOOD"
    elif (( pct >= 60 )); then color="$YEL"; grade="FAIR"
    elif (( pct >= 40 )); then color="$YEL"; grade="DEGRADED"
    fi

    printf "  ${BLD}%d / %d${RST}  (${color}${BLD}%d%% — %s${RST})\n\n" "$score_total" "$score_max" "$pct" "$grade"

    printf "  ["
    for ((i=0; i<bar_len; i++)); do printf "${color}█${RST}"; done
    for ((i=bar_len; i<50; i++)); do printf "${DIM}░${RST}"; done
    printf "]\n"
}

print_device_summary_table() {
    echo ""
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    printf "${BLD}  ALL DEVICES SUMMARY${RST}\n"
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    echo ""

    # Table header
    printf "  ${BLD}%-4s %-26s %-14s %-13s %-8s %-20s %s${RST}\n" \
        "" "Name" "Status" "Type" "RSSI" "Battery" "Health"
    printf "  ${DIM}%-4s %-26s %-14s %-13s %-8s %-20s %s${RST}\n" \
        "────" "──────────────────────────" "──────────────" "─────────────" "────────" "────────────────────" "────────"

    # Print each device row
    echo -e "$DEVICE_SUMMARIES" | while IFS='|' read -r icon name status dtype rssi battery health protocol; do
        [[ -z "$name" ]] && continue

        # Color the status
        local status_colored
        if [[ "$status" == "CONNECTED" ]]; then
            status_colored="${GRN}● Connected${RST}"
        else
            status_colored="${DIM}○ Disconnected${RST}"
        fi

        # Color RSSI
        local rssi_colored
        if [[ "$rssi" == "--" || -z "$rssi" ]]; then
            rssi_colored="${DIM}--${RST}"
        else
            local rval=$rssi
            if (( rval > -60 )); then rssi_colored="${GRN}${rssi}${RST}"
            elif (( rval > -75 )); then rssi_colored="${YEL}${rssi}${RST}"
            else rssi_colored="${RED}${rssi}${RST}"
            fi
        fi

        # Truncate name
        local short_name="${name:0:25}"
        local short_batt="${battery:0:19}"

        printf "  %-4s %-26s %-14b %-13s %-8b %-20s %b\n" \
            "$icon" "$short_name" "$status_colored" "$dtype" "$rssi_colored" "$short_batt" "$health"
    done

    echo ""
}

print_recommendations() {
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    printf "${BLD}  RECOMMENDATIONS${RST}\n"
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"
    echo ""

    local rec_num=1
    local has_recs=false

    # Check A2DP congestion
    local has_a2dp
    has_a2dp=$(echo "$BT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bt = d.get('SPBluetoothDataType', [{}])[0]
for dev in bt.get('device_connected', []):
    if isinstance(dev, dict):
        for name, info in dev.items():
            if 'A2DP' in info.get('device_services', ''):
                print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

    if [[ "$has_a2dp" == "yes" ]]; then
        printf "  ${RED}%d.${RST} Disconnect audio devices when doing precision work\n" "$rec_num"
        printf "     ${DIM}A2DP streaming starves other BT devices of bandwidth${RST}\n\n"
        rec_num=$((rec_num + 1))
        has_recs=true
    fi

    # Check mouse button mode
    local bmode
    bmode=$(defaults read com.apple.AppleMultitouchMouse MouseButtonMode 2>/dev/null || echo "")
    if [[ "$bmode" == "OneButton" ]]; then
        printf "  ${YEL}%d.${RST} Fix MouseButtonMode → TwoButton\n" "$rec_num"
        printf "     ${DIM}Run: $0 --fix${RST}\n\n"
        rec_num=$((rec_num + 1))
        has_recs=true
    fi

    # Check for BLE mouse
    local has_ble_mouse
    has_ble_mouse=$(echo "$BT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bt = d.get('SPBluetoothDataType', [{}])[0]
for dev in bt.get('device_connected', []):
    if isinstance(dev, dict):
        for name, info in dev.items():
            if info.get('device_minorType') == 'Mouse' and 'BLE' in info.get('device_services', ''):
                print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

    if [[ "$has_ble_mouse" == "yes" ]]; then
        printf "  ${YEL}%d.${RST} Use a USB receiver (e.g. Logi Bolt) for your mouse\n" "$rec_num"
        printf "     ${DIM}~1ms polling vs 7.5–15ms BLE intervals${RST}\n\n"
        rec_num=$((rec_num + 1))
        has_recs=true
    fi

    # Check for low battery on any connected device
    echo "$BT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bt = d.get('SPBluetoothDataType', [{}])[0]
for dev in bt.get('device_connected', []):
    if isinstance(dev, dict):
        for name, info in dev.items():
            for k, v in info.items():
                if 'battery' in k.lower() and 'level' in k.lower():
                    try:
                        level = int(str(v).replace('%','').strip())
                        if level <= 20:
                            print(f'{name}|{level}')
                    except: pass
" 2>/dev/null | while IFS='|' read -r dname dlevel; do
        printf "  ${YEL}%d.${RST} Charge %s (battery at %s%%)\n" "$rec_num" "$dname" "$dlevel"
        printf "     ${DIM}Low battery can cause erratic behavior and dropouts${RST}\n\n"
        rec_num=$((rec_num + 1))
        has_recs=true
    done

    # Check high BT error count (filtered, same as check_hid_events)
    local bt_errors
    bt_errors=$(/usr/bin/log show --predicate 'subsystem == "com.apple.bluetooth"' --last 5m --style compact 2>/dev/null \
        | grep -i 'error\|disconnect\|fail\|timeout' \
        | grep -ivc 'error (null)\|BundleID does not exist\|battery fetch failed\|ALREADY_NOT_DISCOVERABLE\|Disconnected with no nearby' \
        2>/dev/null | tr -d '[:space:]' || echo "0")
    [[ -z "$bt_errors" ]] && bt_errors=0

    if (( bt_errors > 20 )); then
        printf "  ${RED}%d.${RST} High Bluetooth error rate (%d real errors in 5 min)\n" "$rec_num" "$bt_errors"
        printf "     ${DIM}Try: Toggle Bluetooth off/on, or restart your Mac${RST}\n\n"
        rec_num=$((rec_num + 1))
        has_recs=true
    fi

    # General
    printf "  ${GRN}%d.${RST} Keep firmware updated for all devices\n" "$rec_num"
    printf "     ${DIM}Check companion apps (Logi Options+, etc.) for updates${RST}\n\n"

    if [[ "$has_recs" == false ]]; then
        printf "  ${GRN}No critical issues detected.${RST}\n\n"
    fi
}

# ─────────────────────────────────────────────────────────────
#  --fix mode
# ─────────────────────────────────────────────────────────────

apply_fixes() {
    printf "\n${BLD}${CYN}Applying recommended fixes...${RST}\n\n"

    local current_mode
    current_mode=$(defaults read com.apple.AppleMultitouchMouse MouseButtonMode 2>/dev/null || echo "not set")

    if [[ "$current_mode" == "OneButton" ]]; then
        echo "  Fixing MouseButtonMode: OneButton → TwoButton"
        defaults write com.apple.AppleMultitouchMouse MouseButtonMode -string TwoButton
        defaults write com.apple.driver.AppleBluetoothMultitouch.mouse MouseButtonMode -string TwoButton
        ok "MouseButtonMode set to TwoButton"
        warn "Log out and back in for this to take full effect"
    else
        ok "MouseButtonMode already OK (${current_mode})"
    fi

    echo ""

    local logi_cpu
    logi_cpu=$(ps aux 2>/dev/null | grep "logioptionsplus_agent" | grep -v grep | awk '{sum+=$3} END {printf "%.1f", sum}' 2>/dev/null || echo "0")

    if (( $(echo "$logi_cpu > 3.0" | bc -l 2>/dev/null || echo 0) )); then
        echo "  Restarting Logi Options+ agent (CPU: ${logi_cpu}%)..."
        killall logioptionsplus_agent 2>/dev/null || true
        sleep 2
        ok "Logi agent restarted (will auto-launch via launchd)"
    else
        ok "Logi agent CPU normal — no restart needed"
    fi

    echo ""
    printf "${GRN}${BLD}  Fixes applied.${RST}\n"
    printf "  ${DIM}Run $0 again to verify improvements.${RST}\n\n"
}

# ─────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────

run_diagnostic() {
    printf "\n${BLD}════════════════════════════════════════════════════════════${RST}\n"
    printf "${BLD}  BLUETOOTH DIAGNOSTIC — ALL DEVICES${RST}\n"
    printf "${BLD}  %s${RST}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${BLD}════════════════════════════════════════════════════════════${RST}\n"

    score_total=0
    score_max=0
    DEVICE_SUMMARIES=""

    # Collect data once
    collect_device_data

    # 1. Controller
    check_controller

    # 2. Per-device diagnostics
    header "2" "DEVICE-BY-DEVICE DIAGNOSTICS"

    local device_count=0
    while IFS='|' read -r status name dtype addr svc fw rssi battery vendor; do
        [[ -z "$name" ]] && continue
        diagnose_device "$status" "$name" "$dtype" "$addr" "$svc" "$fw" "$rssi" "$battery" "$vendor"
        ((device_count++)) || true
    done <<< "$(parse_all_devices)"

    if (( device_count == 0 )); then
        warn "No Bluetooth devices found (paired or connected)"
    else
        info ""
        info "Total devices scanned: ${device_count}"
    fi

    # 3. System-wide checks
    check_congestion
    check_hid_events
    check_logi_software

    # Summary
    print_device_summary_table
    print_score
    echo ""
    print_recommendations
}

if [[ "$FIX_MODE" == true ]]; then
    apply_fixes
    exit 0
fi

if [[ "$WATCH_MODE" == true ]]; then
    echo "Continuous monitoring mode (every ${WATCH_INTERVAL}s). Press Ctrl+C to stop."
    trap 'echo -e "\n${GRN}Monitoring stopped.${RST}"; exit 0' INT
    while true; do
        clear
        run_diagnostic
        printf "${DIM}  Next check in ${WATCH_INTERVAL}s... (Ctrl+C to stop)${RST}\n"
        sleep "$WATCH_INTERVAL"
    done
else
    run_diagnostic
fi
