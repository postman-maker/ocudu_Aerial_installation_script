#!/usr/bin/env bash
# ============================================================================
# kubernetes/operators/install-operators.sh
#
# Installs the cluster-side components OCUDU + Aerial need on a GH200 worker:
#   1. Node Feature Discovery (NFD)
#   2. NVIDIA GPU Operator           (GH200 driver, container toolkit, device plugin)
#   3. NVIDIA Network Operator       (RDMA, Multus, SR-IOV/DPDK, whereabouts)
#   4. SR-IOV Network Operator       (VF creation + SR-IOV device plugin)
#   5. PTP Operator (linuxptp)       (fronthaul timing - ptp4l/phc2sys)
#
# Requires: a running cluster, kubectl + helm v3, cluster-admin context.
# Run from this directory:  ./install-operators.sh
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v kubectl >/dev/null || { echo "kubectl required"; exit 1; }
command -v helm >/dev/null || { echo "helm v3 required"; exit 1; }

echo "== Helm repos =="
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
helm repo add sriov-network-operator https://k8snetworkplumbingwg.github.io/sriov-network-operator || true
helm repo add jetstack https://charts.jetstack.io || true
helm repo update

echo "== 1/5 Node Feature Discovery =="
helm upgrade --install nfd nvidia/node-feature-discovery \
  --namespace node-feature-discovery --create-namespace --wait

echo "== 2/5 NVIDIA GPU Operator (GH200) =="
# GH200 needs the OPEN kernel modules. driver.version pinned to the Aerial 26-1
# validated branch - adjust to your validated driver if needed.
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace --wait \
  -f "${HERE}/gpu-operator-values.yaml"

echo "== 3/5 NVIDIA Network Operator (Multus + RDMA + whereabouts) =="
helm upgrade --install network-operator nvidia/network-operator \
  --namespace nvidia-network-operator --create-namespace --wait \
  -f "${HERE}/network-operator-values.yaml"

echo "== 4/5 SR-IOV Network Operator =="
helm upgrade --install sriov-network-operator sriov-network-operator/sriov-network-operator \
  --namespace sriov-network-operator --create-namespace --wait \
  --set sriovOperatorConfig.deploy=true

echo "== 5/5 PTP Operator (linuxptp) =="
# The linuxptp/ptp-operator provides ptp4l + phc2sys as a managed DaemonSet.
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/ptp-operator/master/deploy/00-namespace.yaml || true
helm upgrade --install ptp-operator oci://ghcr.io/k8snetworkplumbingwg/ptp-operator-chart \
  --namespace openshift-ptp --create-namespace 2>/dev/null \
  || echo "WARN: install the PTP operator manually (see kubernetes/README.md) if the chart ref differs."

echo
echo "DONE. Next:"
echo "  kubectl apply -f ${HERE}/../sriov/    # VF policies + Multus NADs"
echo "  kubectl apply -f ${HERE}/../ptp/      # PtpConfig (fronthaul slave)"
echo "  helm upgrade --install ocudu ${HERE}/../helm/ocudu -f <your-values.yaml>"
