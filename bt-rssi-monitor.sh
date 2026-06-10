#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  bt-rssi-monitor.sh — RSSI Monitor for Blue Element Keyboard
#
#  Uses bluetoothd's unified log to extract Classic BT RSSI
#  (the only reliable source for Classic BT HID signal)
#
#  Usage:
#    ./bt-rssi-monitor.sh                  # one-shot
#    ./bt-rssi-monitor.sh --watch          # live stream
#    ./bt-rssi-monitor.sh --watch --interval=2  # custom interval
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

WATCH=false; INTERVAL=3

for arg in "$@"; do
  case "$arg" in
    --watch|-w) WATCH=true ;;
    --interval=*) INTERVAL="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--watch] [--interval=N]"
      exit 0 ;;
  esac
done

# Get the latest RSSI sample from bluetoothd
get_rssi() {
  /usr/bin/log show --predicate '
    subsystem == "com.apple.bluetooth" AND
    composedMessage CONTAINS "Classic [0xd]"
  ' --last "${1:-3}s" --style compact 2>/dev/null |
  grep -oE 'rssi -?[0-9]+' | tail -1 | awk '{print $2}' || echo ""
}

rssi_bar() {
  local r=$1
  if [ "$r" -ge -50 ]; then printf -- "${GRN}████████  Excellent${RST}"
  elif [ "$r" -ge -65 ]; then printf -- "${GRN}███████░  Good${RST}"
  elif [ "$r" -ge -75 ]; then printf -- "${YEL}████░░░░  Fair${RST}"
  elif [ "$r" -ge -85 ]; then printf -- "${YEL}███░░░░░  Weak${RST}"
  else printf -- "${RED}█░░░░░░░  Poor${RST}"; fi
}

if [ "$WATCH" = false ]; then
  printf -- "\n${BLD}${CYN}╔════════════════════════════════════════╗${RST}\n"
  printf -- "${BLD}${CYN}║  Blue Element Keyboard — RSSI Monitor  ║${RST}\n"
  printf -- "${BLD}${CYN}╚════════════════════════════════════════╝${RST}\n\n"
  printf -- "  Sampling last 15 seconds...\n"

  # Warm up — ensure bluetoothd has logged at least one Classic RSSI entry
  sleep 2

  SAMPLES=""
  for ((i=0; i<5; i++)); do
    S=$(get_rssi 3 || true)
    if [ -n "$S" ]; then
      [ -z "$SAMPLES" ] && SAMPLES="$S" || SAMPLES="$SAMPLES\n$S"
    fi
    sleep 1
  done

  # If still no data, try one last broad catch
  if [ -z "$SAMPLES" ]; then
    S=$(get_rssi 10 || true)
    [ -n "$S" ] && SAMPLES="$S"
  fi

  if [ -z "$SAMPLES" ]; then
    printf -- "\n  ${RED}✖ Could not read keyboard RSSI${RST}\n"
    printf -- "  ${DIM}Is the Blue Element Keyboard connected?${RST}\n\n"
    exit 1
  fi

  AVG=$(echo -e "$SAMPLES" | awk '{s+=$1; n++} END{printf "%.0f", s/n}')
  MIN=$(echo -e "$SAMPLES" | awk 'BEGIN{m=999}{if($1<m) m=$1} END{printf "%.0f", m}')
  MAX=$(echo -e "$SAMPLES" | awk 'BEGIN{m=-999}{if($1>m) m=$1} END{printf "%.0f", m}')
  SAMPLE_COUNT=$(echo -e "$SAMPLES" | wc -l | tr -d ' ')

  if   [ "$AVG" -ge -50 ]; then C="$GRN"
  elif [ "$AVG" -ge -75 ]; then C="$YEL"
  else C="$RED"; fi

  printf -- "\n  ${BLD}RSSI:${RST}  ${C}%s dBm${RST}\n\n" "$AVG"
  printf "  Signal:  "
  rssi_bar "$AVG"
  printf "\n\n"
  printf -- "  ${DIM}Range:  %s dBm to %s dBm${RST}\n" "$MIN" "$MAX"
  printf -- "  ${DIM}Samples taken: %s${RST}\n" "$SAMPLE_COUNT"
  echo
  echo

else
  printf -- "\n${BLD}${CYN}╔════════════════════════════════════════════╗${RST}\n"
  printf -- "${BLD}${CYN}║  Blue Element Keyboard — RSSI Live Stream  ║${RST}\n"
  printf -- "${BLD}${CYN}╚════════════════════════════════════════════╝${RST}\n"
  printf -- "${DIM}  Interval: ${INTERVAL}s  |  Ctrl+C to stop${RST}\n\n"
  printf -- "  %-11s %6s  %-20s %s\n" "Time" "RSSI" "Signal" "Keystrokes (TX)"
  printf -- "  %-11s %6s  %-20s %s\n" "────" "────" "──────" "────────────────"

  while true; do
    S=$(get_rssi 2)
    if [ -n "$S" ]; then
      if   [ "$S" -ge -50 ]; then C="$GRN"
      elif [ "$S" -ge -75 ]; then C="$YEL"
      else C="$RED"; fi
      NOW=$(date +%H:%M:%S)
      BAR=$(rssi_bar "$S")
      TX=$(/usr/bin/log show --predicate '
        subsystem == "com.apple.bluetooth" AND
        composedMessage CONTAINS "Classic [0xd]"
      ' --last "${INTERVAL}s" --style compact 2>/dev/null |
        grep -oE 'tx \[S=[ 0-9]+' | tail -1 | grep -oE '[0-9]+' || echo "?")
      printf -- "  %s  ${C}%4s dBm${RST}  %-20s TX: %s\n" "$NOW" "$S" "$BAR" "$TX"
    else
      printf -- "  %s  ${DIM}%6s${RST}  ${DIM}%-20s${RST}\n" "$(date +%H:%M:%S)" "--" "No data (keyboard idle?)"
    fi
    sleep "$INTERVAL"
  done
fi
