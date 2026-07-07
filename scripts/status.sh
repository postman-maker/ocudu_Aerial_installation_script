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

svc() { # name [extra-note]
  local u="$1" note="${2:-}"
  local act; act="$(systemctl is-active "$u" 2>/dev/null)"
  local res; res="$(systemctl show -p Result --value "$u" 2>/dev/null)"
  local rc;  rc="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
  local label color
  case "$act" in
    active)       label="RUNNING";  color="$g" ;;   # process up (NOTE: PTP 'up' != 'synced')
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
  [[ -n "$note" ]] && printf '  %s' "$note"
  printf '\n'
}

# Derive the actual PTP SYNC state (process 'RUNNING' does NOT mean 'locked').
ptp4l_sync() {
  local link; link="$(cat "/sys/class/net/${PTP_IFNAME}/operstate" 2>/dev/null)"
  if [[ "$link" != up ]]; then printf '%sSYNC:NO-LINK%s (connect O-RU/T-GM to %s)' "$y" "$x" "$PTP_IFNAME"; return; fi
  local rms; rms="$(journalctl -u ocudu-ptp4l -n 60 --no-pager 2>/dev/null | grep -oE 'rms +[0-9]+' | tail -1 | grep -oE '[0-9]+')"
  local pstate; pstate="$(journalctl -u ocudu-ptp4l -n 80 --no-pager 2>/dev/null | grep -oE 'FAULTY|LISTENING|UNCALIBRATED|SLAVE|MASTER' | tail -1)"
  if [[ -n "$rms" ]]; then
    if   (( rms < 100 )); then printf '%sSYNC:LOCKED%s (rms=%sns)' "$g" "$x" "$rms"
    else                       printf '%sSYNC:ACQUIRING%s (rms=%sns, want <100)' "$y" "$x" "$rms"; fi
  elif [[ "$pstate" == SLAVE ]]; then printf '%sSYNC:ACQUIRING%s (slave, servo starting)' "$y" "$x"
  elif [[ -n "$pstate" ]];       then printf '%sSYNC:%s%s (not yet slave)' "$y" "$pstate" "$x"
  else                                printf '%sSYNC:UNKNOWN%s (no data yet)' "$y" "$x"; fi
}
phc2sys_sync() {
  local link; link="$(cat "/sys/class/net/${PTP_IFNAME}/operstate" 2>/dev/null)"
  [[ "$link" != up ]] && { printf '%sSYNC:NO-LINK%s' "$y" "$x"; return; }
  local off; off="$(journalctl -u ocudu-phc2sys -n 40 --no-pager 2>/dev/null | grep -oE 'offset +-?[0-9]+' | tail -1 | grep -oE '\-?[0-9]+')"
  if [[ -n "$off" ]]; then
    local a=${off#-}
    if (( a < 100 )); then printf '%sSYNC:LOCKED%s (offset=%sns)' "$g" "$x" "$off"
    else                   printf '%sSYNC:ACQUIRING%s (offset=%sns)' "$y" "$x" "$off"; fi
  else printf '%sSYNC:UNKNOWN%s (no data yet)' "$y" "$x"; fi
}

# CU operational note: is the N2/NGAP association to the AMF actually up?
cu_note() {
  [[ "$(systemctl is-active ocudu-cu 2>/dev/null)" == active ]] || { printf '(not started)'; return; }
  if ss -np --sctp 2>/dev/null | grep -qE ':38412'; then printf '%sN2:UP%s' "$g" "$x"
  else printf '%sN2:DOWN%s (core reachable?)' "$r" "$x"; fi
}
# DU operational note: cell up, still bringing up, or intentionally waiting.
du_note() {
  [[ "$(systemctl is-active ocudu-du 2>/dev/null)" == active ]] || { printf 'awaiting fronthaul/RU (start after PTP lock)'; return; }
  if journalctl -u ocudu-du -n 300 --no-pager 2>/dev/null | grep -qiE 'DU started|Cell pci='; then printf '%scell:UP%s' "$g" "$x"
  else printf '%sbringing up OFH/cell%s' "$y" "$x"; fi
}

hd "systemd services   [RUNNING=process up  STANDBY=idle  FAILED=error ; notes show link/sync state]"
svc ocudu-cu      "$(cu_note)"
svc ocudu-du      "$(du_note)"
svc ocudu-ptp4l   "$(ptp4l_sync)"
svc ocudu-phc2sys "$(phc2sys_sync)"

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
    echo "  ${u}: STANDBY (not started yet) - nothing to report"
  fi
done
echo
