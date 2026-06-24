# OCUDU + NVIDIA Aerial 26-1 installer — HPE DL384 Gen12 (GH200)

Automated, phase-based installer that prepares an **HPE ProLiant Compute DL384
Gen12** server (NVIDIA **GH200 Grace Hopper**, `aarch64`) and installs:

- **NVIDIA Aerial Framework 26-1** — GPU-accelerated 5G/6G pipeline runtime
  (optionally also the Aerial CUDA-Accelerated RAN / cuBB container from NGC).
- **OCUDU** built as **both CU (`ocu`) and DU (`odu`)** — an O-RAN split 7.2
  capable gNB. CU and DU run co-located on this one host.

## Files

| File | Purpose |
|------|---------|
| `config.env` | All site/hardware values. **Edit before running.** |
| `install.sh` | Phase-based installer/orchestrator. Run as root. |
| `README.md`  | This document. |

## Quick start

```bash
# 1. Discover hardware to fill in config.env
sudo ./install.sh --show-nics      # NIC names + PCI addresses (ConnectX-7)
sudo ./install.sh --show-cpu       # CPU topology for core isolation

# 2. Edit every "CHANGE ME" in config.env (interfaces, IPs, MACs, PLMN, NGC key…)
$EDITOR config.env

# 3. Base OS / drivers / NIC stack / kernel tuning, then REBOOT
sudo ./install.sh host-prep drivers doca tuning
sudo reboot

# 4. After reboot: container runtime, Aerial, OCUDU, networking, configs
sudo ./install.sh docker aerial ocudu network configs verify

# 5. Start the gNB (CU first, then DU)
sudo systemctl enable --now ocudu-cu ocudu-du
```

`sudo ./install.sh all` runs every phase in order, but the kernel/GRUB/driver
phases need a reboot in the middle, so the two-step flow above is recommended.

## Phases

`host-prep` → build deps + RT/low-latency kernel + SSH · `drivers` → NVIDIA
open driver + CUDA 12.9 · `doca` → ConnectX-7 OFED/DPDK + linuxptp · `tuning` →
hugepages/isolcpus/IOMMU/vfio via GRUB + TuneD · `docker` → Docker + NVIDIA
Container Toolkit · `aerial` → Aerial Framework 26-1 (+optional NGC container) ·
`ocudu` → build CU **and** DU · `network` → NG IP, FH MTU + VF, PTP · `configs`
→ generate `cu.yml`/`du.yml` + systemd units · `verify` → sanity checks.

## Network interface plan — answering "what else is needed?"

The BOM has **2× ConnectX-7 dual-port** adapters = **4 × 200G ports**. You named
two (FH and NG). Here is the full set of interfaces the deployment actually
consumes, and how the 4 ports are allocated:

| # | Port (example) | Role | Stack / notes |
|---|----------------|------|---------------|
| 1 | `enp1s0f0` | **Fronthaul (FH)** | O-RAN **split 7.2** to the O-RU. Bound to **DPDK/`vfio-pci`** via an SR-IOV **VF**, jumbo MTU 9600. **Carries PTP** too. |
| 2 | `enp1s0f1` | **NG** | **N2** (NGAP/SCTP → AMF) **and N3** (GTP-U → UPF) toward the 5G core. Normal kernel networking. |
| 3 | `enp2s0f0` | **Management / OAM / SSH** | Admin, **SSH**, SMO, `apt`/NGC pulls. Strongly recommended to keep separate from FH/NG. |
| 4 | `enp2s0f1` | **Spare / PTP / 2nd FH** | A 2nd fronthaul cell, NG redundancy, or a dedicated PTP/timing link. |

Interfaces that are needed but **do not consume a physical port**:

- **F1 (CU ↔ DU)** and **E1 (CU-CP ↔ CU-UP)** — because CU and DU are
  **co-located on this host**, these run over **loopback** (`127.0.10.x`). No
  cable/port required. The installer wires these automatically.
- **PTP / SyncE timing** — split 7.2 requires tight sync (LLS-C3, the FH switch
  acts as PTP grandmaster). PTP normally **shares the FH port** using hardware
  timestamping on the ConnectX-7; the installer sets up `ptp4l` + `phc2sys`. Use
  port #4 only if your timing source is physically separate from the RU path.
- **iLO (out-of-band management)** — the `BD505A` iLO Advanced license uses the
  server's dedicated iLO port, **separate** from the 4 data ports above. Use it
  for remote power/console; it is not part of this script.

So beyond your FH and NG ports, plan for at least **a management/SSH port**, and
account for **PTP timing on the FH port**. F1/E1 are internal.

## Things you MUST set in `config.env`

- NIC identities: `FH_IFNAME`, `FH_PCI`, `FH_VF_PCI`, `FH_RU_MAC`, `FH_DU_MAC`,
  `FH_VLAN`, `NG_IFNAME`, `NG_LOCAL_IP`, `AMF_ADDR`, `MGMT_IFNAME`.
- CPU isolation: `ISOLATED_CPUS` / `HOUSEKEEPING_CPUS`, `HUGEPAGES_1G`.
- Radio/core: `PLMN`, `TAC`, `DL_ARFCN`, `NR_BAND`, `CHANNEL_BW_MHZ`.
- Aerial: `AERIAL_FRAMEWORK_REF` (the 26-1 tag/branch) and, if you want the
  cuBB container, `NGC_API_KEY` + `AERIAL_CUBB_IMAGE`.

## Prerequisites & caveats

- **Ubuntu 22.04 / 24.04 (arm64)** with a **real-time / low-latency kernel**.
- **SR-IOV** must be enabled in BIOS and on the NIC (`mlxconfig … SRIOV_EN=1`)
  for the fronthaul VF.
- **CUDA 12.9** + the **open** GPU kernel modules are required on GH200.
- The Aerial CUDA-Accelerated RAN container needs an **NGC entitlement**; the
  open-source Aerial Framework builds without credentials.
- The generated `ru_ofh` timing values (`t1a_*`, `ta4`, port IDs, compression)
  are **examples** — tune them per your specific O-RU's integration guide.
- The script logs to `/var/log/ocudu-aerial-install.log` and records completed
  phases under `/var/lib/ocudu-aerial-install/`.

## References

- OCUDU: <https://gitlab.com/ocudu/ocudu> · docs <https://docs.ocudu.org>
- NVIDIA Aerial Framework: <https://github.com/NVIDIA/aerial-framework>
- NVIDIA Aerial CUDA-Accelerated RAN 26.1 documentation (docs.nvidia.com/aerial)
