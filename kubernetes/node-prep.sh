#!/usr/bin/env bash
# ============================================================================
# kubernetes/node-prep.sh
#
# Host-level preparation for a Kubernetes WORKER node that will run the OCUDU
# CU/DU + NVIDIA Aerial 26-1 on an HPE DL384 Gen12 (GH200).
#
# These steps CANNOT be done by cluster operators and must run on each RAN node
# BEFORE the node joins / is scheduled:
#   * real-time / low-latency kernel
#   * GRUB cmdline: 1G hugepages, isolcpus, IOMMU passthrough, vfio
#   * enable SR-IOV in the ConnectX-7 firmware (mlxconfig)
#   * node labels/taints the operators and the Helm chart key off
#
# The NVIDIA GPU Operator installs the GPU driver/toolkit, and the SR-IOV
# Network Operator creates the VFs at runtime - so we do NOT do those here.
#
# Usage: sudo ./node-prep.sh            # uses ../config.env for tunables
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../config.env}"
[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || echo "WARN: ${CONFIG_FILE} not found, using defaults" >&2
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root"; exit 1; }

ISOLATED_CPUS="${ISOLATED_CPUS:-4-71}"
HOUSEKEEPING_CPUS="${HOUSEKEEPING_CPUS:-0-3}"
HUGEPAGES_1G="${HUGEPAGES_1G:-32}"
NODE_LABEL_ROLE="${NODE_LABEL_ROLE:-ocudu.io/ran-node=true}"

echo "== 1/4 base packages =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    pciutils ethtool iproute2 linux-lowlatency || \
    echo "WARN: install an RT kernel (Ubuntu Pro 'linux-realtime') if low-latency is insufficient"

echo "== 2/4 GRUB: hugepages / isolcpus / IOMMU / vfio =="
cmd="default_hugepagesz=1G hugepagesz=1G hugepages=${HUGEPAGES_1G}"
cmd+=" isolcpus=${ISOLATED_CPUS} nohz_full=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}"
cmd+=" rcu_nocb_poll irqaffinity=${HOUSEKEEPING_CPUS} iommu.passthrough=1 iommu.strict=0"
cmd+=" vfio_pci.disable_idle_d3=1 processor.max_cstate=0 cpufreq.default_governor=performance"
mkdir -p /etc/default/grub.d
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT ${cmd}\"" \
    > /etc/default/grub.d/99-ocudu-aerial.cfg
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg
printf 'vfio-pci\nvfio_iommu_type1\n' > /etc/modules-load.d/vfio.conf

echo "== 3/4 enable SR-IOV in ConnectX-7 firmware (mlxconfig) =="
if command -v mlxconfig >/dev/null 2>&1; then
  mst start 2>/dev/null || true
  for dev in $(mst status -v 2>/dev/null | awk '/pciconf/{print $3}'); do
    echo "  configuring $dev: SRIOV_EN=1 NUM_OF_VFS=8"
    mlxconfig -y -d "$dev" set SRIOV_EN=1 NUM_OF_VFS=8 || true
  done
  echo "  NOTE: a firmware reset/reboot is required for mlxconfig changes."
else
  echo "  WARN: mlxconfig not found (install via DOCA/MFT). Enable SR-IOV manually:"
  echo "        mlxconfig -d <dev> set SRIOV_EN=1 NUM_OF_VFS=8"
fi

echo "== 4/4 node label =="
echo "  After the node is in the cluster, label it for scheduling:"
echo "    kubectl label node <node> ${NODE_LABEL_ROLE} --overwrite"
echo "    kubectl label node <node> feature.node.kubernetes.io/network-sriov.capable=true --overwrite"

echo
echo "DONE. REBOOT this node so the kernel cmdline + firmware SR-IOV take effect."
echo "Verify after reboot:"
echo "  grep -i huge /proc/meminfo ; cat /proc/cmdline ; lspci | grep -i mellanox"
