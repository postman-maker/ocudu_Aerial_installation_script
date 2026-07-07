#!/usr/bin/env bash
# ============================================================================
# scripts/core-up.sh
#
# Bring up (or tear down) OCUDU's bundled Open5GS 5G core in Docker on THIS
# host, for a co-located first-light setup (CORE_MODE=local).
#
#   ./core-up.sh up      # build+start only the 5gc service, add UE-pool route
#   ./core-up.sh down     # stop the core
#   ./core-up.sh logs     # follow core logs
#   ./core-up.sh webui    # print the WebUI URL for subscriber management
#
# Subscribers: edit ocudu/docker/open5gs/subscriber_db.csv (default test UEs are
# already present) or use the WebUI at http://localhost:9999.
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../config.env}"
[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true

OCUDU_DIR="${OCUDU_DIR:-/opt/ocudu}"
DOCKER_DIR="${OCUDU_DIR}/docker"
AMF_IP="${LOCAL_CORE_AMF_IP:-10.53.1.2}"
UE_POOL="${LOCAL_CORE_UE_POOL:-10.45.0.0/16}"

command -v docker >/dev/null || { echo "docker not installed - run: sudo ./install.sh docker"; exit 1; }
[[ -d "$DOCKER_DIR" ]] || { echo "Not found: $DOCKER_DIR (run 'sudo ./install.sh ocudu' to clone OCUDU)"; exit 1; }

# Open5GS' setup_tun.py programs UE-NAT via legacy iptables (libiptc), which
# needs the host's xtables/NAT modules loaded. Ubuntu 26.04 defaults to nftables
# and does not auto-load them, so the container fails with
# "iptables who? (do you need to insmod?)". Load + persist them on the host.
load_nat_modules() {
  local mods="ip_tables iptable_nat iptable_filter nf_nat nf_conntrack xt_MASQUERADE"
  echo "== Loading host NAT modules for the Open5GS UE tunnel =="
  local m ok=1
  for m in $mods; do
    sudo modprobe "$m" 2>/dev/null || { echo "  WARN: modprobe $m failed"; ok=0; }
  done
  printf '%s\n' $mods | sudo tee /etc/modules-load.d/ocudu-open5gs-nat.conf >/dev/null
  [[ $ok -eq 1 ]] && echo "  NAT modules loaded (persisted to /etc/modules-load.d/)." \
    || echo "  Some modules missing - if the core still fails on ogstun, check the kernel's xtables support."
}

case "${1:-up}" in
  up)
    load_nat_modules
    echo "== Building + starting Open5GS 5GC (docker) =="
    ( cd "$DOCKER_DIR" && docker compose up -d 5gc )
    echo "== Adding host route to UE pool ${UE_POOL} via ${AMF_IP} =="
    sudo ip route replace "${UE_POOL}" via "${AMF_IP}" 2>/dev/null \
      || echo "  (route add skipped/failed - retry once the core is healthy)"
    echo "Done. AMF/UPF at ${AMF_IP}. WebUI: http://localhost:9999"
    echo "Point the CU at it: config.env CORE_MODE=local  ->  sudo ./install.sh configs"
    ;;
  down)
    ( cd "$DOCKER_DIR" && docker compose down )
    ;;
  logs)
    ( cd "$DOCKER_DIR" && docker compose logs -f 5gc )
    ;;
  webui)
    echo "Open5GS WebUI: http://localhost:9999  (subscriber add/edit)"
    ;;
  *)
    echo "usage: $0 {up|down|logs|webui}"; exit 1 ;;
esac
