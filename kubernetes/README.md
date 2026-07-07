# OCUDU + Aerial 26-1 on Kubernetes (GH200)

Kubernetes deployment of **OCUDU CU (`ocu`) + DU (`odu`)** with **NVIDIA Aerial
26-1** on an **HPE DL384 Gen12 / GH200** node, using **Helm + Multus + SR-IOV +
PTP Operator + GPU Operator**.

```
kubernetes/
├── node-prep.sh                # bare-metal node prep (run + reboot first)
├── operators/
│   ├── install-operators.sh    # NFD, GPU, Network, SR-IOV, PTP operators
│   ├── gpu-operator-values.yaml
│   └── network-operator-values.yaml
├── sriov/                      # VF policies + Multus NADs (FH + NG)
├── ptp/ptp-config.yaml         # fronthaul PTP slave (PtpConfig)
└── helm/ocudu/                 # the CU+DU Helm chart
images/Dockerfile.ocudu        # builds the ocu+odu container image
```

## Architecture

| Plane | How it is realised on k8s |
|-------|---------------------------|
| **GPU (Aerial L1)** | NVIDIA **GPU Operator** (open kmods on GH200) → `nvidia.com/gpu` requested by the DU pod; `runtimeClassName: nvidia`. |
| **Fronthaul (FH, 7.2)** | **SR-IOV** VF bound to **`vfio-pci`** (DPDK) via `SriovNetworkNodePolicy` → Multus NAD `fh-dpdk` attached to the **DU**. The VF PCI address is injected into `du.yml` at runtime. |
| **NG (N2/N3)** | **SR-IOV** netdevice VF with **static IPAM** → Multus NAD `ng-net` attached to the **CU**. Bind IP == `core.ngLocalIp`. |
| **F1 (CU↔DU)** | Separate pods → F1 over the **cluster pod network** via the headless CU **Service** (SCTP + UDP). *SCTP must be enabled in your primary CNI.* |
| **Timing (PTP)** | **PTP Operator** runs `ptp4l`/`phc2sys` (G.8275.1, LLS-C3) on the FH PF per `kubernetes/ptp/ptp-config.yaml`. |
| **Mgmt / SSH / OAM** | Node's management NIC + standard k8s API/kubectl; out-of-band via **iLO**. |

> The 4 ConnectX-7 ports map exactly as in the bare-metal plan: **FH** and **NG**
> are consumed by SR-IOV VFs; keep one port for **management**; the 4th is a
> spare (2nd cell / NG redundancy / dedicated PTP). **F1/E1 consume no NIC** —
> here they ride the cluster network instead of loopback because CU and DU are
> separate pods.

## Install order

```bash
# 0. On EACH GH200 RAN node (host level), then reboot:
sudo kubernetes/node-prep.sh
sudo reboot

# 1. Label the node so operators + chart schedule onto it:
kubectl label node <node> ocudu.io/ran-node=true --overwrite

# 2. Cluster operators (GPU / Network / SR-IOV / PTP / NFD):
kubernetes/operators/install-operators.sh

# 3. SR-IOV VF policies + Multus NADs (edit pfNames/VLAN/IPAM first!):
kubectl create namespace ran
kubectl apply -f kubernetes/sriov/

# 4. Fronthaul PTP slave (edit interface/domain), then VERIFY it locks:
kubectl apply -f kubernetes/ptp/ptp-config.yaml
kubectl -n openshift-ptp logs -l app=linuxptp-daemon -c linuxptp-daemon-container | grep -i rms

# 5. Build & push the OCUDU image (on the GH200 / arm64):
docker build -f images/Dockerfile.ocudu -t <registry>/ocudu:26-1 \
  --build-arg OCUDU_REF=main .
docker push <registry>/ocudu:26-1

# 6. Deploy CU + DU:
helm upgrade --install ocudu kubernetes/helm/ocudu -n ran \
  --set image.repository=<registry>/ocudu \
  --set core.amfAddr=10.60.0.100 --set core.ngLocalIp=10.60.0.10
```

## What you MUST edit

- `kubernetes/sriov/10-…fh.yaml`, `11-…ng.yaml`: `pfNames` (FH/NG PF names + VF
  ranges), and the FH **VLAN** / NG **static IP** in `20-`/`21-`.
- `kubernetes/ptp/ptp-config.yaml`: FH `interface` and PTP `domainNumber`.
- `helm/ocudu/values.yaml`: `image.repository`, `core.*`, `cell.*`,
  `du.ruMac/duMac/vlan`, GPU/CPU/hugepage resource sizes.
- `operators/gpu-operator-values.yaml`: pin `driver.version` to your Aerial 26-1
  validated driver branch if required.

## Caveats / assumptions

- Requires the node prepared by `node-prep.sh` (RT kernel, 1G hugepages,
  isolcpus, IOMMU passthrough, vfio, NIC SR-IOV firmware) — operators do **not**
  do these.
- **SCTP** must be enabled in the primary CNI for F1-C (and N2 if NG used cluster
  net). With SR-IOV NG (default here) N2 leaves via the VF, so only F1 needs CNI
  SCTP.
- The PTP/GPU/SR-IOV operator chart references may differ by version; pin to the
  releases validated for Aerial 26-1. The PTP operator install in
  `install-operators.sh` may need adjusting to your distribution.
- `ru_ofh` timing/compression values in the DU ConfigMap are **examples** — tune
  per your O-RU's integration guide.
- `helm template` was not run in this environment (no network access to the Helm
  release host); render locally with `helm template ocudu kubernetes/helm/ocudu`
  before applying.
