#!/usr/bin/env bash
# Toggle DGX Spark between headless (no GUI) and graphical desktop.
# Headless frees unified RAM for inference (often ~10–15 GiB); SSH/LAN stay up.
#
# Usage (on Spark):
#   spark-headless status
#   sudo spark-headless on     # boot to multi-user.target (no GNOME)
#   sudo spark-headless off    # boot to graphical.target (desktop)
#   sudo spark-headless now    # drop GUI this session (isolate multi-user)
#   sudo spark-headless gui    # start GUI this session (isolate graphical)
#
# Do NOT apt purge ubuntu-desktop — that can remove Spark platform packages.
# With multi-user.target the desktop simply never starts.
set -euo pipefail

cmd="${1:-status}"

current_default() {
  systemctl get-default 2>/dev/null || echo "(unknown)"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run with: sudo $0 $*"
    exit 1
  fi
}

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

case "${cmd}" in
  -h|--help|help) usage 0 ;;
  status|st)
    echo "systemd default target: $(current_default)"
    if systemctl is-active --quiet graphical.target 2>/dev/null; then
      echo "graphical.target: active (desktop session may be running)"
    else
      echo "graphical.target: inactive"
    fi
    if systemctl is-active --quiet multi-user.target 2>/dev/null; then
      echo "multi-user.target: active"
    fi
    echo "MemAvailable: $(awk '/MemAvailable:/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?')"
    echo
    echo "Headless (recommended for inference): sudo spark-headless on && sudo reboot"
    echo "Restore desktop:                     sudo spark-headless off && sudo reboot"
    ;;
  on|headless|server)
    need_root on
    systemctl set-default multi-user.target
    echo "Default target → multi-user.target (no GUI after reboot)."
    echo "Reboot to apply: sudo reboot"
    echo "Or drop GUI now: sudo spark-headless now"
    ;;
  off|desktop|gui-default)
    need_root off
    systemctl set-default graphical.target
    echo "Default target → graphical.target (desktop after reboot)."
    echo "Reboot to apply: sudo reboot"
    echo "Or start GUI now: sudo spark-headless gui"
    ;;
  now|isolate-headless)
    need_root now
    systemctl isolate multi-user.target
    echo "Isolated to multi-user.target (GUI stopped for this boot)."
    ;;
  gui|isolate-gui)
    need_root gui
    systemctl isolate graphical.target
    echo "Isolated to graphical.target (desktop started for this boot)."
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage 1
    ;;
esac
