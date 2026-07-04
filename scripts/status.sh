#!/usr/bin/env bash
# ============================================================================
# scripts/status.sh - one-shot health view of the OCUDU stack on this host.
#
#   ./status.sh          # summary of core, CU, DU, N2, F1, PTP, NIC, hugepages
#
# Read-only. Safe to run anytime.
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../config.env}"
[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" 2>/dev/null || true
FH_IFNAME="${FH_IFNAME:-enp1s0f0np0}"
PTP_IFNAME="${PTP_IFNAME:-$FH_IFNAME}"
g=$'\033[32m'; r=$'\033[31m'; y=$'\033[33m'; b=$'\033[34m'; x=$'\033[0m'
hd(){ printf '\n%s== %s ==%s\n' "$b" "$1" "$x"; }
yn(){ [[ "$1" == "$2" ]] && printf '%sOK%s' "$g" "$x" || printf '%s%s%s' "$r" "$3" "$x"; }

svc() { # name
  local u="$1"
  local act; act="$(systemctl is-active "$u" 2>/dev/null)"
  local res; res="$(systemctl show -p Result --value "$u" 2>/dev/null)"
  local rc;  rc="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
  local label color
  case "$act" in
    active)       label="RUNNING";  color="$g" ;;   # up and serving
    activating)   label="STARTING"; color="$y" ;;
    deactivating) label="STOPPING"; color="$y" ;;
    failed)       label="FAILED";   color="$r" ;;   # crashed / error
    inactive)
      if [[ "$res" == "success" || -z "$res" ]]; then
        label="STANDBY";  color="$b"                # intentionally not started (no error)
      else
        label="STOPPED:${res}"; color="$r"
      fi ;;
    *) label="${act:-ABSENT}"; color="$r" ;;
  esac
  printf '  %-18s %s%-9s%s' "$u" "$color" "$label" "$x"
  [[ -n "${rc:-}" && "${rc:-0}" != 0 ]] && printf '  (restarts=%s%s%s)' "$y" "$rc" "$x"
  printf '\n'
}

hd "systemd services   [RUNNING=up  STANDBY=idle/not started  STARTING  FAILED=error]"
svc ocudu-cu; svc ocudu-du; svc ocudu-ptp4l; svc ocudu-phc2sys

hd "5G core (Open5GS docker)"
if command -v docker >/dev/null 2>&1; then
  docker ps --filter name=open5gs_5gc --format '  {{.Names}}  {{.Status}}' 2>/dev/null | grep . \
    || echo "  (open5gs_5gc not running - scripts/core-up.sh up)"
else echo "  docker not installed"; fi

hd "N2 / NGAP  (CU <-> AMF, SCTP 38412)"
if command -v ss >/dev/null 2>&1; then
  ss -np --sctp 2>/dev/null | grep -E ':38412' | sed 's/^/  /' | head -4 \
    || echo "  no SCTP assoc on 38412 (is the CU up and the core reachable?)"
fi
journalctl -u ocudu-cu -n 200 --no-pager 2>/dev/null | grep -iE 'N2: Connection to AMF.*completed' | tail -1 | sed 's/^/  last: /'

hd "F1  (CU <-> DU, SCTP 38472)"
command -v ss >/dev/null && { ss -np --sctp 2>/dev/null | grep -E ':38472' | sed 's/^/  /' | head -4 || true; }
journalctl -u ocudu-cu -n 200 --no-pager 2>/dev/null | grep -iE 'F1-C: (Listening|Connection)' | tail -1 | sed 's/^/  CU: /'
journalctl -u ocudu-du -n 200 --no-pager 2>/dev/null | grep -iE 'F1-C: Connection to CU' | tail -1 | sed 's/^/  DU: /'

hd "PTP  (fronthaul timing on ${PTP_IFNAME})"
if ip link show "$PTP_IFNAME" >/dev/null 2>&1; then
  printf '  %-16s link=%s\n' "$PTP_IFNAME" "$(cat /sys/class/net/$PTP_IFNAME/operstate 2>/dev/null)"
fi
journalctl -u ocudu-ptp4l -n 100 --no-pager 2>/dev/null | grep -iE 'rms' | tail -1 | sed 's/^/  ptp4l: /' \
  || echo "  no ptp4l rms lines yet (needs FH link + T-GM; rms<10 = locked)"

hd "DU cell / OFH"
journalctl -u ocudu-du -n 300 --no-pager 2>/dev/null | grep -iE 'Cell pci=|gNodeB started|DU started|Fronthaul|late|dropped' | tail -6 | sed 's/^/  /' \
  || echo "  DU not started yet"

hd "Fronthaul NIC / VF / hugepages"
for i in "$FH_IFNAME" "${NG_IFNAME:-}"; do
  [[ -n "$i" ]] && ip link show "$i" >/dev/null 2>&1 && \
    printf '  %-16s link=%s mtu=%s\n' "$i" "$(cat /sys/class/net/$i/operstate)" "$(cat /sys/class/net/$i/mtu)"
done
[[ -e "/sys/class/net/${FH_IFNAME}/device/virtfn0" ]] \
  && echo "  FH VF: $(basename "$(readlink -f /sys/class/net/${FH_IFNAME}/device/virtfn0)")" \
  || echo "  FH VF: none (created by 'install.sh network')"
grep -E 'HugePages_Total|HugePages_Free' /proc/meminfo | sed 's/^/  /'

hd "errors since the CURRENT start (stale crash-loops excluded)"
for u in ocudu-cu ocudu-du; do
  since="$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null)"
  if [[ -n "$since" ]]; then
    n="$(journalctl -u "$u" --since "$since" --no-pager 2>/dev/null | grep -iE 'error|fail|assert' | tail -5)"
    [[ -n "$n" ]] && echo "$n" | sed "s/^/  ${u}: /" || echo "  ${u}: none since $since"
  else
    echo "  ${u}: not running"
  fi
done
echo
