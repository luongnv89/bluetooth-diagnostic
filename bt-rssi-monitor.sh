#!/usr/bin/env bash
# ------------------------------------------------------------
#  bt-rssi-monitor.sh -- Multi-device Bluetooth RSSI Monitor
#
#  Shows all connected BT devices at startup, then lets you
#  select one to run RSSI + link diagnostics.
#
#  Data sources:
#    Classic HID -> bluetoothd Classic connection logs
#    BLE         -> system_profiler SPBluetoothDataType
#    A2DP audio  -> bluetoothd A2DP LinkQualityReport
#
#  Usage:
#    ./bt-rssi-monitor.sh                         # scan -> select -> oneshot
#    ./bt-rssi-monitor.sh --watch                 # scan -> select -> live
#    ./bt-rssi-monitor.sh "Keyboard"              # skip scan, name-match
#    ./bt-rssi-monitor.sh --watch --interval=2    # fast live updates
# ------------------------------------------------------------

set -euo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

WATCH=false; INTERVAL=3; TARGET_DEVICE=""

for arg in "$@"; do
  case "$arg" in
    --watch|-w) WATCH=true ;;
    --interval=*) INTERVAL="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--watch] [--interval=N] [device_name]"
      exit 0 ;;
    --*) ;;
    *) TARGET_DEVICE="$arg" ;;
  esac
done

# ------------------------------------------------------------
#  1. DISCOVER ALL CONNECTED BLUETOOTH DEVICES
# ------------------------------------------------------------
discover_devices() {
  system_profiler SPBluetoothDataType 2>/dev/null | awk '
    BEGIN { in_connected = 0 }
    /^[ \t]*Not Connected:/ { in_connected = 0 }
    /^[ \t]*Connected:/ { in_connected = 1; next }
    in_connected && /^          [^ ]/ && /:$/ {
      if (name != "" && addr != "") print_record()
      name = $0; gsub(/^[ \t]*|:$/, "", name)
      addr = ""; svc = ""; rssi = ""; battery = ""
    }
    in_connected && /Address:/ { addr = $NF }
    in_connected && /Services:/ {
      sub(/.*Services:[ \t]*/, "")
      svc = $0
    }
    in_connected && /RSSI:/ { rssi = $NF }
    in_connected && /Battery Level:/ {
      lvl = $0; gsub(/.*Battery Level:[ \t]*|[ \t]*%.*$/, "", lvl)
      battery = battery ? battery "," lvl : lvl
    }
    END { if (name != "" && addr != "") print_record() }

    function print_record() {
      source = "unknown"
      if (svc ~ /HID/ && svc !~ /BLE/) source = "classic_hid"
      else if (svc ~ /A2DP/) source = "a2dp"
      else if (svc ~ /BLE/) source = "ble"
      else if (index(svc, "ACL") > 0) source = "classic"
      else source = "profile"
      printf "%s|%s|%s|%s|%s|%s\n", name, addr, svc, source, rssi, battery
    }
  '
}

# ------------------------------------------------------------
#  2. GET CLASSIC HID HANDLE FROM IOREG  (e.g. handle=13 -> 0xd)
# ------------------------------------------------------------
get_hid_handles() {
  python3 << 'PYEOF'
import subprocess, re
r = subprocess.run(['ioreg', '-r', '-c', 'IOBluetoothDevice', '-l', '-w', '0'],
                   capture_output=True, text=True)
h = None
addr = None
for line in r.stdout.splitlines():
    m = re.search(r'"ConnectionHandle" = (\d+)', line)
    if m: h = m.group(1)
    m = re.search(r'"BD_ADDR" = <([0-9a-fA-F]+)>', line)
    if m: addr = m.group(1)
    if h and addr and h != '4095':
        addr_str = '-'.join(addr[i:i+2] for i in range(0, len(addr), 2))
        print(f'{addr_str}|{h}')
        h = None; addr = None
PYEOF
}

# ------------------------------------------------------------
#  3. BUILD DEVICE LIST
# ------------------------------------------------------------
build_device_list() {
  DEV_NAMES=(); DEV_ADDRS=(); DEV_SVCS=(); DEV_TYPES=()
  DEV_RSSI=(); DEV_BATT=(); DEV_HANDLES=()

  # Parse discover_devices output
  while IFS='|' read -r name addr svc type rssi batt; do
    DEV_NAMES+=("$name")
    DEV_ADDRS+=("$addr")
    DEV_SVCS+=("$svc")
    DEV_TYPES+=("$type")
    DEV_RSSI+=("$rssi")
    DEV_BATT+=("$batt")
    DEV_HANDLES+=("")
  done < <(discover_devices)

  # Get HID handles
  local -a HID_RECORDS=()
  local hid_raw
  hid_raw=$(get_hid_handles 2>/dev/null || true)
  if [ -n "$hid_raw" ]; then
    while IFS='|' read -r h_addr h_handle; do
      if [ -n "$h_addr" ] && [ -n "$h_handle" ]; then
        HID_RECORDS+=("$h_addr|$h_handle")
      fi
    done <<< "$hid_raw"
  fi

  # Match handles to classic HID devices
  if [ ${#HID_RECORDS[@]} -gt 0 ]; then
    for hid in "${HID_RECORDS[@]}"; do
      local h_addr="${hid%%|*}"
      local h_handle="${hid##*|}"
      for i in "${!DEV_ADDRS[@]}"; do
        if [ "${DEV_TYPES[$i]}" = "classic_hid" ]; then
          local dev_norm hid_norm
          dev_norm=$(echo "${DEV_ADDRS[$i]}" | tr -cd 'A-Za-z0-9' | tr '[:upper:]' '[:lower:]') || true
          hid_norm=$(echo "$h_addr" | tr -cd 'A-Za-z0-9' | tr '[:upper:]' '[:lower:]') || true
          if [ "$dev_norm" = "$hid_norm" ]; then
            DEV_HANDLES[i]="$h_handle"
            break
          fi
        fi
      done
    done
  fi
}

# ------------------------------------------------------------
#  4. DISPLAY MENU AND SELECT DEVICE
# ------------------------------------------------------------
select_device() {
  if [ ${#DEV_NAMES[@]} -eq 0 ]; then
    printf -- "\n  ${RED}x No connected Bluetooth devices found${RST}\n"
    printf -- "  ${DIM}Make sure Bluetooth is on and devices are paired${RST}\n\n"
    exit 1
  fi

  local device_count=${#DEV_NAMES[@]}

  if [ -n "$TARGET_DEVICE" ]; then
    for i in "${!DEV_NAMES[@]}"; do
      if echo "${DEV_NAMES[$i]}" | grep -qi "$TARGET_DEVICE"; then
        DEV_INDEX=$i
        return
      fi
    done
    printf -- "\n  ${RED}x No device matching '${TARGET_DEVICE}'${RST}\n"
    printf -- "  ${DIM}Use one of:${RST}\n"
    for n in "${DEV_NAMES[@]}"; do printf -- "    o ${DIM}%s${RST}\n" "$n"; done
    echo
    exit 1
  fi

  printf -- "\n${BLD}${CYN}============================================${RST}\n"
  printf -- "${BLD}${CYN}    Bluetooth Device Diagnostics${RST}\n"
  printf -- "${BLD}${CYN}============================================${RST}\n\n"

  printf -- "  ${BLD}%-3s %-28s %-14s %-8s  %s${RST}\n" "#" "Device" "Type" "RSSI" "Battery"
  printf -- "  ${DIM}%-3s %-28s %-14s %-8s  %s${RST}\n" "--" "------" "----" "----" "-------"

  for i in "${!DEV_NAMES[@]}"; do
    local num=$((i+1))
    local type_label=""
    local rssi_display=""
    local batt_display="${DIM}--${RST}"

    case "${DEV_TYPES[$i]}" in
      classic_hid)
        type_label="Classic HID"
        if [ -n "${DEV_HANDLES[$i]}" ]; then
          rssi_display="${DIM}(live)${RST}"
        else
          rssi_display="${DIM}--${RST}"
        fi ;;
      a2dp)
        type_label="Audio A2DP"
        rssi_display="${DIM}(live)${RST}" ;;
      ble)
        type_label="BLE"
        if [ -n "${DEV_RSSI[$i]}" ]; then
          rssi_display="${DEV_RSSI[$i]} dBm"
        else
          rssi_display="${DIM}--${RST}"
        fi ;;
      *)
        type_label="${DEV_TYPES[$i]}"
        rssi_display="${DIM}--${RST}" ;;
    esac

    if [ -n "${DEV_BATT[$i]}" ]; then
      batt_display="${DEV_BATT[$i]}"
    fi

    printf -- "  ${BLD}%2d)${RST} %-28s ${DIM}%-14s${RST} %-8s  %s\n" \
      "$num" "${DEV_NAMES[$i]}" "$type_label" "$rssi_display" "$batt_display"
  done

  printf -- "\n"

  while true; do
    printf -- "  ${BLD}Select device (1-%d, 0 to quit):${RST} " "$device_count"
    read -r choice
    if [ "$choice" = "0" ]; then printf -- "  ${DIM}Cancelled${RST}\n"; exit 0; fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$device_count" ]; then
      DEV_INDEX=$((choice - 1))
      break
    fi
  done
}

# ------------------------------------------------------------
#  5. RSSI READING FUNCTIONS (per device type)
# ------------------------------------------------------------

classic_rssi_log() {
  local handle="$1"
  local secs="${2:-3}"
  local hex
  printf -v hex "0x%x" "$handle"
  /usr/bin/log show \
    --predicate 'subsystem == "com.apple.bluetooth" AND composedMessage CONTAINS "Classic ['"$hex"']"' \
    --last "${secs}s" --style compact 2>/dev/null |
  grep -oE 'rssi -?[0-9]+' | tail -1 | awk '{print $2}' || echo ""
}

classic_tx_count() {
  local handle="$1"
  local secs="${2:-3}"
  local hex
  printf -v hex "0x%x" "$handle"
  /usr/bin/log show \
    --predicate 'subsystem == "com.apple.bluetooth" AND composedMessage CONTAINS "Classic ['"$hex"']"' \
    --last "${secs}s" --style compact 2>/dev/null |
  grep -oE 'tx \[S=[ 0-9]+' | tail -1 | grep -oE '[0-9]+' || echo "?"
}

a2dp_rssi() {
  /usr/bin/log show \
    --predicate 'subsystem == "com.apple.bluetooth" AND composedMessage CONTAINS[c] "A2DP LinkQualityReport"' \
    --last "${1:-3}s" --style compact 2>/dev/null | tail -1
}

profiler_rssi() {
  local addr="$1"
  system_profiler SPBluetoothDataType 2>/dev/null |
  awk -v a="$addr" '
    /Address:/ { cur = $NF }
    /RSSI:/ && cur == a { print $NF; exit }
  '
}

profiler_battery() {
  local addr="$1"
  system_profiler SPBluetoothDataType 2>/dev/null |
  awk -v a="$addr" '
    /Address:/ { cur = $NF; batt = "" }
    /Battery Level:/ && cur == a {
      gsub(/.*Battery Level:[ \t]*|[ \t]*%.*$/, "")
      batt = batt ? batt "," $0 : $0
    }
    /^[ \t]*$|^[ \t]*[^ ]/ { if (cur == a && batt != "") print batt; cur = "" }
    END { if (cur == a && batt != "") print batt }
  ' | tail -1
}

rssi_bar() {
  local r=$1
  if [ "$r" -ge -50 ]; then printf -- "${GRN}########  Excellent${RST}"
  elif [ "$r" -ge -65 ]; then printf -- "${GRN}#######o  Good${RST}"
  elif [ "$r" -ge -75 ]; then printf -- "${YEL}####ooooo  Fair${RST}"
  elif [ "$r" -ge -85 ]; then printf -- "${YEL}###oooooo  Weak${RST}"
  else printf -- "${RED}#oooooooo  Poor${RST}"; fi
}

a2dp_summary() {
  local line="$1"
  local rssi txpwr retx
  rssi=$(echo "$line" | grep -oE 'RSSI =  -?[0-9]+' | awk '{print $3}') || true
  txpwr=$(echo "$line" | grep -oE 'TxPwr =  -?[0-9]+' | awk '{print $3}') || true
  retx=$(echo "$line" | grep -oE 'ReTx =  [0-9.]+%' | awk '{print $3}') || true
  echo "$rssi|$txpwr|$retx"
}

# ------------------------------------------------------------
#  6. ONE-SHOT DIAGNOSTIC
# ------------------------------------------------------------
oneshot() {
  local type="$1" name="$2" addr="$3" handle="$4" svc="$5"

  printf -- "\n  ${BLD}Diagnosing:${RST} ${name}\n"
  printf -- "  ${DIM}Services:  %s${RST}\n" "$svc"
  printf -- "  ${DIM}Address:   %s${RST}\n\n" "$addr"
  printf -- "  Sampling...\n"

  local AVG="" MIN="" MAX="" CNT="0" EXTRA=""

  if [ "$type" = "classic_hid" ] && [ -n "$handle" ]; then
    sleep 2  # warm up log buffer
    local SAMPLES=""
    for ((i=0; i<5; i++)); do
      S=$(classic_rssi_log "$handle" 3)
      [ -n "$S" ] && { [ -z "$SAMPLES" ] && SAMPLES="$S" || SAMPLES="$SAMPLES\n$S"; }
      sleep 1
    done
    [ -z "$SAMPLES" ] && S=$(classic_rssi_log "$handle" 10) && [ -n "$S" ] && SAMPLES="$S"

    if [ -z "$SAMPLES" ]; then
      printf -- "\n  ${RED}x No RSSI data for '${name}'${RST}\n"
      printf -- "  ${DIM}Classic HID device may be idle - try typing${RST}\n\n"
      exit 1
    fi
    AVG=$(echo -e "$SAMPLES" | awk '{s+=$1; n++} END{printf "%.0f", s/n}')
    MIN=$(echo -e "$SAMPLES" | awk 'BEGIN{m=999}{if($1<m) m=$1} END{printf "%.0f", m}')
    MAX=$(echo -e "$SAMPLES" | awk 'BEGIN{m=-999}{if($1>m) m=$1} END{printf "%.0f", m}')
    CNT=$(echo -e "$SAMPLES" | wc -l | tr -d ' ')
    local tx_s
    tx_s=$(classic_tx_count "$handle" 15) || true
    EXTRA="TX: ${tx_s} keystrokes/15s"

  elif [ "$type" = "a2dp" ]; then
    local line
    line=$(a2dp_rssi 15) || true
    if [ -n "$line" ]; then
      local s
      s=$(a2dp_summary "$line") || true
      local a2dp_rssi txpwr retx
      a2dp_rssi=$(echo "$s" | awk -F'|' '{print $1}') || true
      txpwr=$(echo "$s" | awk -F'|' '{print $2}') || true
      retx=$(echo "$s" | awk -F'|' '{print $3}') || true
      AVG="$a2dp_rssi"; MIN="$a2dp_rssi"; MAX="$a2dp_rssi"; CNT="1"
      [ -n "$txpwr" ] && EXTRA="TxPower: ${txpwr} dBm  |  ReTx: ${retx}"
    fi
    # Fallback: try profiler (BLE RSSI may not match A2DP addr, but worth a shot)
    if [ -z "$AVG" ]; then
      local prof_rssi
      prof_rssi=$(profiler_rssi "$addr") || true
      if [ -n "$prof_rssi" ]; then
        AVG="$prof_rssi"; MIN="$prof_rssi"; MAX="$prof_rssi"; CNT="1"
      fi
      # Try fetching classic log RSSI too (without specific handle)
      if [ -z "$AVG" ]; then
        local classic_log
        classic_log=$(/usr/bin/log show --predicate 'subsystem == "com.apple.bluetooth" AND composedMessage CONTAINS[c] "A2DP LinkQualityReport"' --last 30s --style compact 2>/dev/null | tail -1) || true
        [ -n "$classic_log" ] && {
          local cr
          cr=$(echo "$classic_log" | grep -oE 'RSSI =  -?[0-9]+' | awk '{print $3}') || true
          [ -n "$cr" ] && { AVG="$cr"; MIN="$cr"; MAX="$cr"; CNT="1"; EXTRA="RSSI from A2DP log (no streaming?)"; }
        }
      fi
    fi

  else
    AVG=$(profiler_rssi "$addr")
    if [ -n "$AVG" ]; then
      MIN="$AVG"; MAX="$AVG"; CNT="1"
      local batt
      batt=$(profiler_battery "$addr") || true
      [ -n "$batt" ] && EXTRA="Battery: ${batt}"
    fi
  fi

  if [ -z "$AVG" ]; then
    printf -- "\n  ${RED}x Could not read RSSI${RST}\n\n"; exit 1
  fi

  if   [ "$AVG" -ge -50 ]; then C="$GRN"
  elif [ "$AVG" -ge -75 ]; then C="$YEL"
  else C="$RED"; fi

  printf -- "\n  ${BLD}RSSI:${RST}  ${C}%s dBm${RST}\n\n" "$AVG"
  printf "  Signal:  "; rssi_bar "$AVG"; printf "\n\n"
  printf -- "  ${DIM}Range:  %s dBm -> %s dBm${RST}\n" "$MIN" "$MAX"
  printf -- "  ${DIM}Samples: %s${RST}\n" "$CNT"
  [ -n "$EXTRA" ] && printf -- "  ${DIM}%s${RST}\n" "$EXTRA"
  echo
}

# ------------------------------------------------------------
#  7. LIVE STREAM
# ------------------------------------------------------------
livestream() {
  local type="$1" name="$2" addr="$3" handle="$4"

  printf -- "\n${BLD}${CYN}==================================${RST}\n"
  printf -- "${BLD}${CYN}  Live: %s${RST}\n" "$name"
  printf -- "${BLD}${CYN}==================================${RST}\n"
  printf -- "${DIM}  Interval: ${INTERVAL}s  |  Ctrl+C to stop${RST}\n\n"

  if [ "$type" = "classic_hid" ] && [ -n "$handle" ]; then
    printf -- "  %-11s %6s  %-20s  %s\n" "Time" "RSSI" "Signal" "Activity"
    printf -- "  %-11s %6s  %-20s  %s\n" "----" "----" "------" "--------"
    while true; do
      S=$(classic_rssi_log "$handle" 2)
      if [ -n "$S" ]; then
        [ "$S" -ge -50 ] && C="$GRN" || [ "$S" -ge -75 ] && C="$YEL" || C="$RED"
        TX=$(classic_tx_count "$handle" "$INTERVAL")
        BAR=$(rssi_bar "$S")
        printf -- "  %s  ${C}%4s dBm${RST}  %-20s  TX: %s\n" "$(date +%H:%M:%S)" "$S" "$BAR" "$TX"
      else
        printf -- "  %s  ${DIM}%6s${RST}  ${DIM}%-20s${RST}\n" "$(date +%H:%M:%S)" "--" "No data (keyboard idle?)"
      fi
      sleep "$INTERVAL"
    done

  elif [ "$type" = "a2dp" ]; then
    printf -- "  %-11s %6s  %-20s  %s\n" "Time" "RSSI" "Signal" "Link Quality"
    printf -- "  %-11s %6s  %-20s  %s\n" "----" "----" "------" "------------"
    while true; do
      local line
      line=$(a2dp_rssi "$INTERVAL") || true
      if [ -n "$line" ]; then
        local s
        s=$(a2dp_summary "$line") || true
        local S txpwr retx
        S=$(echo "$s" | awk -F'|' '{print $1}') || true
        txpwr=$(echo "$s" | awk -F'|' '{print $2}') || true
        retx=$(echo "$s" | awk -F'|' '{print $3}') || true
        if [ -n "$S" ]; then
          [ "$S" -ge -50 ] && C="$GRN" || [ "$S" -ge -75 ] && C="$YEL" || C="$RED"
          BAR=$(rssi_bar "$S")
          printf -- "  %s  ${C}%4s dBm${RST}  %-20s  TxPwr:%s  ReTx:%s\n" \
            "$(date +%H:%M:%S)" "$S" "$BAR" "$txpwr" "$retx"
        fi
      else
        local S
        S=$(profiler_rssi "$addr") || true
        if [ -n "$S" ]; then
          [ "$S" -ge -50 ] && C="$GRN" || [ "$S" -ge -75 ] && C="$YEL" || C="$RED"
          BAR=$(rssi_bar "$S")
          printf -- "  %s  ${C}%4s dBm${RST}  %-20s  (profiler snap)\n" "$(date +%H:%M:%S)" "$S" "$BAR"
        else
          printf -- "  %s  ${DIM}%6s${RST}  ${DIM}%-20s${RST}\n" "$(date +%H:%M:%S)" "--" "No A2DP data"
        fi
      fi
      sleep "$INTERVAL"
    done

  else
    printf -- "  %-11s %6s  %-20s  %s\n" "Time" "RSSI" "Signal" "Battery"
    printf -- "  %-11s %6s  %-20s  %s\n" "----" "----" "------" "-------"
    while true; do
      S=$(profiler_rssi "$addr")
      if [ -n "$S" ]; then
        [ "$S" -ge -50 ] && C="$GRN" || [ "$S" -ge -75 ] && C="$YEL" || C="$RED"
        BAR=$(rssi_bar "$S")
        BATT=$(profiler_battery "$addr")
        [ -z "$BATT" ] && BATT="${DIM}--${RST}"
        printf -- "  %s  ${C}%4s dBm${RST}  %-20s  %s\n" "$(date +%H:%M:%S)" "$S" "$BAR" "$BATT"
      else
        printf -- "  %s  ${DIM}%6s${RST}  ${DIM}%-20s${RST}\n" "$(date +%H:%M:%S)" "--" "No data (polling)"
      fi
      sleep "$INTERVAL"
    done
  fi
}

# ------------------------------------------------------------
#  8. MAIN
# ------------------------------------------------------------

build_device_list
select_device

NAME="${DEV_NAMES[$DEV_INDEX]}"
ADDR="${DEV_ADDRS[$DEV_INDEX]}"
TYPE="${DEV_TYPES[$DEV_INDEX]}"
SVC="${DEV_SVCS[$DEV_INDEX]}"
HANDLE="${DEV_HANDLES[$DEV_INDEX]}"

if [ "$WATCH" = true ]; then
  livestream "$TYPE" "$NAME" "$ADDR" "$HANDLE"
else
  oneshot "$TYPE" "$NAME" "$ADDR" "$HANDLE" "$SVC"
fi
