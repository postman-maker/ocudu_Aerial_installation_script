#!/usr/bin/env bash
# ============================================================================
# install.sh
#
# Unattended-ish installer for:
#   * NVIDIA Aerial Framework 26-1 (GPU-accelerated 5G/6G pipeline runtime)
#   * OCUDU CU (ocu) AND DU (odu) - O-RAN split 7.2 capable gNB
#
# Target platform:
#   HPE ProLiant Compute DL384 Gen12  (NVIDIA GH200 Grace Hopper, aarch64)
#   2x ConnectX-7 dual-port NICs (MCX755106AC) = 4 x 200G ports
#
# The script is phase based and idempotent where practical. Read config.env,
# edit it, then run phases in order. Several phases need a reboot (kernel /
# GRUB / driver) - the script tells you when.
#
#   sudo ./install.sh --show-nics          # discover NIC names / PCI addresses
#   sudo ./install.sh --show-cpu           # discover CPU topology for isolation
#   sudo ./install.sh all                  # run every phase in order
#   sudo ./install.sh host-prep drivers    # run selected phases only
#   sudo ./install.sh --list               # list phases
#
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# ============================================================================
set -o errexit
set -o nounset
set -o pipefail

# --- locate ourselves & load config ----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/ocudu-aerial-install.log}"
STATE_DIR="/var/lib/ocudu-aerial-install"

# ----------------------------------------------------------------------------
# logging helpers
# ----------------------------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
log()  { printf '%s [INFO ] %s\n'  "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf '%s %s[ OK  ]%s %s\n' "$(date '+%F %T')" "$c_grn" "$c_rst" "$*" | tee -a "$LOG_FILE" >&2; }
warn() { printf '%s %s[WARN ]%s %s\n' "$(date '+%F %T')" "$c_ylw" "$c_rst" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '%s %s[ERROR]%s %s\n' "$(date '+%F %T')" "$c_red" "$c_rst" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit 1; }
banner(){ printf '\n%s======== %s ========%s\n' "$c_blu" "$*" "$c_rst" | tee -a "$LOG_FILE" >&2; }

mark_done() { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$1.done"; }
is_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."; }

apt_install() {
  log "apt-get install: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# ----------------------------------------------------------------------------
# preflight: arch / OS sanity, load config
# ----------------------------------------------------------------------------
preflight() {
  banner "Preflight"
  [[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE (copy & edit the template)."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  local arch; arch="$(uname -m)"
  if [[ "$arch" != "aarch64" ]]; then
    warn "Architecture is '$arch' - the DL384/GH200 is aarch64. Continuing, but"
    warn "package repositories below assume arm64/sbsa."
  else
    ok "Architecture aarch64 (GH200 Grace CPU) detected."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
    # NVIDIA CUDA/DOCA sbsa repos only publish for 22.04 / 24.04. Newer Ubuntu
    # (e.g. 26.04 'resolute') has no matching repo, so fall back to ubuntu2404.
    case "${VERSION_ID:-}" in
      22.04) UBUNTU_REPO="ubuntu2204"; ok "Ubuntu 22.04 supported." ;;
      24.04) UBUNTU_REPO="ubuntu2404"; ok "Ubuntu 24.04 supported." ;;
      *) UBUNTU_REPO="ubuntu2404"
         warn "Ubuntu ${VERSION_ID:-?} is newer than Aerial 26-1's validated 22.04/24.04;"
         warn "using NVIDIA '${UBUNTU_REPO}' (sbsa) repositories as the closest supported base."
         warn "If the driver/DKMS fails to build against this kernel, use the distro"
         warn "package instead:  apt install nvidia-driver-580-open cuda-toolkit-12-9" ;;
    esac
    DOCKER_CODENAME="${VERSION_CODENAME:-noble}"
  else
    UBUNTU_REPO="ubuntu2404"
    DOCKER_CODENAME="noble"
    warn "/etc/os-release not found; assuming ${UBUNTU_REPO}."
  fi
  # config.env may override the repo bases explicitly.
  UBUNTU_REPO="${NV_UBUNTU_REPO:-$UBUNTU_REPO}"
  DOCKER_CODENAME="${DOCKER_CODENAME_OVERRIDE:-$DOCKER_CODENAME}"
  export UBUNTU_REPO DOCKER_CODENAME

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L 2>/dev/null | tee -a "$LOG_FILE" >&2 || true
  else
    warn "nvidia-smi not present yet (expected before the 'drivers' phase)."
  fi
  mkdir -p "$STATE_DIR"
  ok "Preflight complete."
}

# ----------------------------------------------------------------------------
# discovery helpers (read-only)
# ----------------------------------------------------------------------------
show_nics() {
  banner "Network interfaces / NICs"
  echo "--- ip link ---"; ip -br link 2>/dev/null || true
  echo; echo "--- Mellanox/NVIDIA ConnectX (lspci) ---"
  lspci -nn 2>/dev/null | grep -iE 'mellanox|connectx|bluefield' || echo "  (none found - is OFED/DOCA installed?)"
  if command -v dpdk-devbind.py >/dev/null 2>&1; then
    echo; echo "--- dpdk-devbind --status ---"; dpdk-devbind.py -s || true
  fi
  if command -v mst >/dev/null 2>&1; then echo; echo "--- mst status ---"; mst status -v || true; fi
}

show_cpu() {
  banner "CPU topology"
  lscpu | grep -iE 'architecture|^cpu\(s\)|on-line|numa|model name|thread|core' || true
  echo; echo "Suggested split: keep cores 0-3 for the OS, isolate the rest for RAN."
}

# ----------------------------------------------------------------------------
# PHASE: host-prep - base packages, realtime/low-latency kernel, build deps
# ----------------------------------------------------------------------------
phase_host_prep() {
  banner "PHASE host-prep"
  apt-get update
  apt_install build-essential cmake make gcc g++ pkg-config git curl wget ca-certificates \
              gnupg lsb-release software-properties-common python3 python3-pip python3-venv \
              ethtool iproute2 net-tools pciutils linux-tools-common \
              tuned chrony hwloc numactl ccache openssh-server

  # OCUDU build dependencies (mbedtls, sctp, yaml-cpp, gtest).
  apt_install libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev

  # FFT backend for OCUDU PHY on ARM.
  case "${OCUDU_FFT}" in
    fftw)  apt_install libfftw3-dev ;;
    armpl) install_armpl ;;
    *) die "Unknown OCUDU_FFT='${OCUDU_FFT}' (use armpl or fftw)" ;;
  esac

  # Low-latency / realtime kernel. OCUDU and Aerial both require it.
  if uname -r | grep -qiE 'realtime|rt|lowlatency'; then
    ok "Realtime/low-latency kernel already running: $(uname -r)"
  else
    warn "Current kernel '$(uname -r)' is not realtime/low-latency."
    apt_install linux-lowlatency || warn "linux-lowlatency not available; install an RT kernel manually (Ubuntu Pro 'linux-realtime')."
    warn "Reboot into the low-latency/RT kernel before running OCUDU/Aerial in production."
  fi

  # SSH: required management/admin interface - make sure it is enabled.
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  ok "SSH server enabled (management/OAM access)."

  mark_done host-prep
  ok "host-prep complete."
}

install_armpl() {
  if [[ -d /opt/arm ]] && ls /opt/arm/modulefiles/armpl* >/dev/null 2>&1; then
    ok "Arm Performance Libraries already present."; return
  fi
  log "Installing Arm Performance Libraries (ARMPL) for the FFT backend."
  apt_install environment-modules
  local ver="24.10"
  ( cd /tmp
    wget --no-check-certificate -O armpl.tar \
      "https://developer.arm.com/-/cdn-downloads/permalink/Arm-Performance-Libraries/Version_${ver}/arm-performance-libraries_${ver}_deb_gcc.tar"
    tar -xf armpl.tar
    cd arm-performance-libraries_${ver}_deb/
    ./arm-performance-libraries_${ver}_deb.sh --accept
  ) || die "ARMPL install failed."
  ok "ARMPL installed under /opt/arm (module: armpl)."
}

# ----------------------------------------------------------------------------
# PHASE: drivers - NVIDIA datacenter driver (open) + CUDA toolkit
# ----------------------------------------------------------------------------
phase_drivers() {
  banner "PHASE drivers (NVIDIA driver + CUDA ${CUDA_VERSION})"
  local keyring="/usr/share/keyrings/cuda-archive-keyring.gpg"
  if [[ ! -f "$keyring" ]]; then
    log "Adding CUDA repository for ${UBUNTU_REPO}/sbsa."
    wget -qO /tmp/cuda-keyring.deb \
      "https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_REPO}/sbsa/cuda-keyring_1.1-1_all.deb"
    dpkg -i /tmp/cuda-keyring.deb
  fi
  apt-get update
  # Open kernel modules are mandatory for Grace Hopper.
  apt_install cuda-toolkit-${CUDA_VERSION} nvidia-open || apt_install cuda-toolkit-${CUDA_VERSION} cuda-drivers
  # GPUDirect / peer memory for GPUDirect RDMA from the NIC to GPU memory.
  apt_install nvidia-peermem-dkms 2>/dev/null || modprobe nvidia_peermem 2>/dev/null || \
    warn "nvidia-peermem not loaded yet; it is required for GPUDirect RDMA fronthaul."

  if ! grep -q 'cuda-' /etc/profile.d/cuda.sh 2>/dev/null; then
    cat >/etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
  fi
  mark_done drivers
  warn "A REBOOT is recommended after driver install. Then verify with: nvidia-smi"
  ok "drivers phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: doca - NIC stack for ConnectX-7 fronthaul (DPDK + rdma-core + linuxptp)
#   NIC_STACK=inbox : inbox mlx5_core + rdma-core + Ubuntu DPDK (robust on new
#                     kernels; ConnectX-7 DPDK uses the *bifurcated* mlx5 PMD, so
#                     NO vfio-pci binding is needed).  <-- default
#   NIC_STACK=doca  : NVIDIA DOCA-OFED host stack (only if you need DOCA/GPUDirect
#                     features and your kernel is supported by DOCA).
# ----------------------------------------------------------------------------
phase_doca() {
  local stack="${NIC_STACK:-inbox}"
  banner "PHASE doca / NIC stack (${stack})"
  case "$stack" in
    inbox)
      # The ConnectX-7 ports already work with the inbox mlx5_core driver and
      # SR-IOV is already enabled in firmware (sriov_totalvfs=16). For OFH we
      # only need userspace: rdma-core (ibverbs + mlx5 provider), DPDK and PTP.
      apt-get update || true
      apt_install rdma-core ibverbs-providers libibverbs-dev ibverbs-utils \
                  dpdk dpdk-dev libdpdk-dev linuxptp mstflint || build_linuxptp
      ok "Inbox mlx5 + DPDK + rdma-core + linuxptp installed (no vfio-pci needed)."
      ;;
    doca)
      local keyring="/usr/share/keyrings/GPG-PUB-KEY-MELLANOX.gpg"
      if [[ ! -f "$keyring" ]]; then
        log "Adding NVIDIA DOCA repository (${UBUNTU_REPO}/arm64-sbsa)."
        wget -qO - https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub \
          | gpg --dearmor -o "$keyring" || warn "Could not import DOCA GPG key automatically."
        echo "deb [signed-by=${keyring}] https://linux.mellanox.com/public/repo/doca/latest/${UBUNTU_REPO}/arm64-sbsa/ ./" \
          > /etc/apt/sources.list.d/doca.list
      fi
      apt-get update || warn "DOCA repo update failed - check the repo URL for your DOCA release."
      apt_install doca-ofed || apt_install doca-all || apt_install rdma-core ibverbs-providers ibverbs-utils
      apt_install linuxptp || build_linuxptp
      command -v mst >/dev/null 2>&1 && mst start 2>/dev/null || true
      warn "A REBOOT may be required so the DOCA-OFED modules load."
      ;;
    *) die "Unknown NIC_STACK='${stack}' (use inbox or doca)" ;;
  esac
  mark_done doca
  ok "doca phase complete. Verify with: ethtool -i ${FH_IFNAME} ; ibv_devices"
}

build_linuxptp() {
  log "Building linuxptp v4.2 from source."
  ( cd /tmp && rm -rf linuxptp && git clone http://git.code.sf.net/p/linuxptp/code linuxptp \
    && cd linuxptp && git checkout v4.2 && make && make install ) || die "linuxptp build failed."
}

# ----------------------------------------------------------------------------
# PHASE: tuning - GRUB cmdline: isolcpus, hugepages, IOMMU, vfio
# ----------------------------------------------------------------------------
phase_tuning() {
  banner "PHASE tuning (GRUB: hugepages / isolcpus / IOMMU / vfio)"
  local cmd="default_hugepagesz=1G hugepagesz=1G hugepages=${HUGEPAGES_1G}"
  cmd+=" isolcpus=${ISOLATED_CPUS} nohz_full=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}"
  cmd+=" rcu_nocb_poll nohz=on irqaffinity=${HOUSEKEEPING_CPUS}"
  cmd+=" iommu.passthrough=1 iommu.strict=0 vfio_pci.disable_idle_d3=1"
  cmd+=" processor.max_cstate=0 cpufreq.default_governor=performance"

  local grubf=/etc/default/grub.d/99-ocudu-aerial.cfg
  mkdir -p /etc/default/grub.d
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT ${cmd}\"" > "$grubf"
  log "Wrote ${grubf}: ${cmd}"
  update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg

  # Load vfio-pci at boot (needed to bind the fronthaul VF for DPDK/OFH).
  echo -e "vfio-pci\nvfio_iommu_type1" > /etc/modules-load.d/vfio.conf
  # Persist runtime hugepages too.
  echo "vm.nr_hugepages = ${HUGEPAGES_1G}" > /etc/sysctl.d/99-hugepages.conf

  # TuneD realtime profile (OCUDU-recommended approach).
  if command -v tuned-adm >/dev/null 2>&1; then
    systemctl stop power-profiles-daemon.service 2>/dev/null || true
    systemctl disable power-profiles-daemon.service 2>/dev/null || true
    tuned-adm profile realtime 2>/dev/null || warn "Could not activate TuneD 'realtime' profile."
    systemctl enable tuned.service 2>/dev/null || true
  fi
  mark_done tuning
  warn "A REBOOT is REQUIRED for GRUB/hugepage/isolcpus changes to take effect."
  ok "tuning phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: docker - Docker engine + NVIDIA Container Toolkit (for Aerial container)
# ----------------------------------------------------------------------------
phase_docker() {
  banner "PHASE docker (engine + NVIDIA Container Toolkit)"
  if ! command -v docker >/dev/null 2>&1; then
    install -m0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME:-noble} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  # NVIDIA container toolkit so containers see the GH200 GPU.
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt_install nvidia-container-toolkit
  fi
  nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
  systemctl enable docker 2>/dev/null || true
  mark_done docker
  ok "docker phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: aerial - NVIDIA Aerial Framework 26-1
#   Builds the open-source framework from GitHub, and (optionally) pulls the
#   Aerial CUDA-Accelerated RAN 26.1 container from NGC if NGC_API_KEY is set.
# ----------------------------------------------------------------------------
phase_aerial() {
  banner "PHASE aerial (NVIDIA Aerial Framework ${AERIAL_FRAMEWORK_REF})"

  # uv: fast Python package/venv manager used by the framework.
  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
      || { apt_install python3-pip; pip3 install --break-system-packages uv 2>/dev/null || true; }
  fi
  # clang/cmake for the C++20 build.
  apt_install clang cmake ninja-build || true

  if [[ -d "${AERIAL_FRAMEWORK_DIR}/.git" ]]; then
    log "Updating existing Aerial Framework checkout."
    git -C "${AERIAL_FRAMEWORK_DIR}" fetch --all --tags --prune
  else
    git clone "${AERIAL_FRAMEWORK_REPO}" "${AERIAL_FRAMEWORK_DIR}"
  fi
  git -C "${AERIAL_FRAMEWORK_DIR}" checkout "${AERIAL_FRAMEWORK_REF}" \
    || warn "Ref '${AERIAL_FRAMEWORK_REF}' not found - check available tags with: git -C ${AERIAL_FRAMEWORK_DIR} tag"

  log "Building Aerial Framework (clang-release preset)."
  ( cd "${AERIAL_FRAMEWORK_DIR}"
    cmake --preset clang-release
    cmake --build out/build/clang-release -j "$(nproc)"
    if [[ -d ran/py ]]; then ( cd ran/py && uv sync ); fi
  ) || warn "Aerial Framework build reported errors - review the log; CUDA 12.9 + a CC>=8 GPU are required."

  # Optional: pull the Aerial CUDA-Accelerated RAN (cuBB) container from NGC.
  if [[ -n "${NGC_API_KEY}" ]]; then
    log "Logging in to NGC and pulling ${AERIAL_CUBB_IMAGE}"
    echo "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin \
      && docker pull "${AERIAL_CUBB_IMAGE}" \
      || warn "NGC pull failed - verify NGC_API_KEY and your Aerial entitlement / image tag."
  else
    warn "NGC_API_KEY empty -> skipping Aerial CUDA-Accelerated RAN container pull."
  fi
  mark_done aerial
  ok "aerial phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: ocudu - build OCUDU (provides ocu=CU and odu=DU)
# ----------------------------------------------------------------------------
phase_ocudu() {
  banner "PHASE ocudu (build CU 'ocu' + DU 'odu', split=${OCUDU_SPLIT})"
  if [[ -d "${OCUDU_DIR}/.git" ]]; then
    git -C "${OCUDU_DIR}" fetch --all --tags --prune
  else
    git clone "${OCUDU_REPO}" "${OCUDU_DIR}"
  fi
  git -C "${OCUDU_DIR}" checkout "${OCUDU_REF}" || warn "OCUDU ref '${OCUDU_REF}' checkout failed."

  # Make ARMPL visible to cmake if selected.
  if [[ "${OCUDU_FFT}" == "armpl" ]]; then
    # shellcheck disable=SC1091
    source /usr/share/modules/init/bash 2>/dev/null || true
    export MODULEPATH="${MODULEPATH:-}:/opt/arm/modulefiles"
    module load armpl 2>/dev/null || true
  fi

  ( cd "${OCUDU_DIR}"
    mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DDU_SPLIT_TYPE="${OCUDU_SPLIT}" -DENABLE_DPDK=ON ../
    make -j "$(nproc)"
  ) || die "OCUDU build failed - see ${LOG_FILE}."

  # Sanity: confirm both CU and DU binaries were produced.
  local ocu="${OCUDU_DIR}/build/apps/ocu/ocu"
  local odu="${OCUDU_DIR}/build/apps/du/odu"
  [[ -x "$ocu" ]] && ok "Built CU: $ocu" || warn "CU binary not found at $ocu"
  [[ -x "$odu" ]] && ok "Built DU: $odu" || warn "DU binary not found at $odu"
  make -C "${OCUDU_DIR}/build" install 2>/dev/null || warn "system-wide 'make install' skipped/failed (optional)."
  mark_done ocudu
  ok "ocudu phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: network - configure NG interface, FH jumbo/MTU, FH VF for DPDK+PTP
# ----------------------------------------------------------------------------
phase_network() {
  banner "PHASE network (NG IP, FH MTU/VF, PTP VF)"

  # --- NG interface (N2/N3 to the 5G core) ---
  if [[ "${CORE_MODE}" == "local" ]]; then
    # Co-located Open5GS in Docker: N2/N3 ride the docker bridge, not the NIC.
    # Only add a host route to the UE pool via the Open5GS container so you can
    # reach connected UEs from the host. (The bridge itself is made by compose.)
    if [[ -n "${LOCAL_CORE_UE_POOL}" ]]; then
      ip route replace "${LOCAL_CORE_UE_POOL}" via "${LOCAL_CORE_AMF_IP}" 2>/dev/null \
        && ok "UE-pool route ${LOCAL_CORE_UE_POOL} via ${LOCAL_CORE_AMF_IP} added" \
        || warn "UE-pool route not added yet - start the core first (scripts/core-up.sh), then re-run."
    fi
    ok "CORE_MODE=local: N2/N3 over docker bridge (AMF ${AMF_ADDR}); physical NG ${NG_IFNAME} left untouched."
  else
    # External core over the physical NG port. Do NOT change the default route
    # (that belongs to the management link); only add a host route to the AMF.
    if ip link show "${NG_IFNAME}" >/dev/null 2>&1; then
      ip link set "${NG_IFNAME}" up
      ip addr replace "${NG_LOCAL_IP}/${NG_PREFIX}" dev "${NG_IFNAME}"
      if [[ -n "${NG_GATEWAY}" ]]; then
        ip route replace "${AMF_ADDR}/32" via "${NG_GATEWAY}" dev "${NG_IFNAME}" 2>/dev/null \
          && ok "Route to AMF ${AMF_ADDR} via ${NG_GATEWAY} added on ${NG_IFNAME}" \
          || warn "Could not add AMF route (AMF may be on the NG subnet already)."
      fi
      ok "NG interface ${NG_IFNAME} = ${NG_LOCAL_IP}/${NG_PREFIX} (AMF ${AMF_ADDR})"
    else
      warn "NG interface ${NG_IFNAME} not found - fix NG_IFNAME in config.env."
    fi
  fi

  # --- Management interface (optional static IP) ---
  if [[ -n "${MGMT_LOCAL_IP}" ]] && ip link show "${MGMT_IFNAME}" >/dev/null 2>&1; then
    ip link set "${MGMT_IFNAME}" up
    ip addr replace "${MGMT_LOCAL_IP}" dev "${MGMT_IFNAME}"
    ok "Management interface ${MGMT_IFNAME} = ${MGMT_LOCAL_IP}"
  fi

  # --- Fronthaul: jumbo frames on the PF, then create one VF for OFH ---
  # ConnectX-7 uses the *bifurcated* mlx5 PMD: the VF STAYS on mlx5_core and
  # DPDK drives it via rdma-core. We do NOT bind it to vfio-pci.
  if ip link show "${FH_IFNAME}" >/dev/null 2>&1; then
    ip link set "${FH_IFNAME}" mtu "${FH_MTU}" up
    ok "FH PF ${FH_IFNAME} MTU=${FH_MTU} up"
    local sriov="/sys/class/net/${FH_IFNAME}/device/sriov_numvfs"
    if [[ -w "$sriov" ]]; then
      echo 0 > "$sriov" 2>/dev/null || true
      echo 1 > "$sriov"
      ip link set "${FH_IFNAME}" vf 0 mac "${FH_DU_MAC}" spoofchk off 2>/dev/null || true
      ip link set "${FH_IFNAME}" vf 0 vlan "${FH_VLAN}" 2>/dev/null || true
      # Auto-detect the VF's PCI address (robust vs guessing the function number).
      local vfpci=""
      [[ -e "/sys/class/net/${FH_IFNAME}/device/virtfn0" ]] && \
        vfpci="$(basename "$(readlink -f "/sys/class/net/${FH_IFNAME}/device/virtfn0")")"
      vfpci="${vfpci:-${FH_VF_PCI}}"
      echo "$vfpci" > "${STATE_DIR}/fh_vf_pci"
      # Bring the VF netdev up so the mlx5 PMD can attach; keep it on mlx5_core.
      for vfnet in /sys/class/net/${FH_IFNAME}/device/virtfn0/net/*; do
        [[ -e "$vfnet" ]] && ip link set "$(basename "$vfnet")" up 2>/dev/null || true
      done
      ok "Created FH VF at PCI ${vfpci} (MAC ${FH_DU_MAC}, VLAN ${FH_VLAN}) on mlx5_core (no vfio bind)"
    else
      warn "SR-IOV not writable at ${sriov} - check the PF name / SR-IOV firmware."
    fi
  else
    warn "FH interface ${FH_IFNAME} not found or down - connect the O-RU/FH switch, then re-run: sudo ./install.sh network"
  fi

  setup_ptp
  mark_done network
  ok "network phase complete."
}

# Return the fronthaul VF PCI: prefer the value detected by phase_network,
# else read it live from sysfs, else fall back to the config value.
fh_vf_pci() {
  if [[ -s "${STATE_DIR}/fh_vf_pci" ]]; then
    cat "${STATE_DIR}/fh_vf_pci"
  elif [[ -e "/sys/class/net/${FH_IFNAME}/device/virtfn0" ]]; then
    basename "$(readlink -f "/sys/class/net/${FH_IFNAME}/device/virtfn0")"
  else
    echo "${FH_VF_PCI}"
  fi
}

# The interface ptp4l actually runs on: a VLAN sub-interface when PTP_VLAN is
# set (O-RAN fronthaul usually tags PTP), else the raw PF.
ptp_run_if() {
  if [[ -n "${PTP_VLAN:-}" ]]; then echo "${PTP_IFNAME}.${PTP_VLAN}"; else echo "${PTP_IFNAME}"; fi
}

setup_ptp() {
  local rif; rif="$(ptp_run_if)"
  log "Configuring PTP (linuxptp) for fronthaul timing on ${rif}."
  timedatectl set-ntp false 2>/dev/null || true   # NTP must be off; PTP is the time source
  systemctl disable --now chrony 2>/dev/null || systemctl disable --now systemd-timesyncd 2>/dev/null || true

  # If PTP rides a VLAN, create the sub-interface now (idempotent).
  local pre=""
  if [[ -n "${PTP_VLAN:-}" ]]; then
    ip link add link "${PTP_IFNAME}" name "${rif}" type vlan id "${PTP_VLAN}" 2>/dev/null || true
    ip link set "${rif}" mtu "${FH_MTU}" up 2>/dev/null || true
    ok "PTP VLAN sub-interface ${rif} (id ${PTP_VLAN}) ready"
    # recreate it on every service start too (survives reboots without network phase)
    pre="ExecStartPre=-/sbin/ip link add link ${PTP_IFNAME} name ${rif} type vlan id ${PTP_VLAN}
ExecStartPre=/sbin/ip link set ${rif} mtu ${FH_MTU} up"
  fi

  mkdir -p /etc/linuxptp
  cat >/etc/linuxptp/ocudu-ptp4l.conf <<EOF
# G.8275.1 multicast profile (LLS-C3, switch = T-GM) for O-RAN 7.2 fronthaul.
[global]
domainNumber            ${PTP_DOMAIN}
slaveOnly               1
priority1               128
priority2               128
network_transport       L2
delay_mechanism         P2P
logAnnounceInterval     -3
logSyncInterval         -4
logMinDelayReqInterval  -4
tx_timestamp_timeout    50
[${rif}]
EOF

  cat >/etc/systemd/system/ocudu-ptp4l.service <<EOF
[Unit]
Description=OCUDU ptp4l (fronthaul PTP slave)
After=network-online.target
[Service]
${pre}
ExecStart=/usr/sbin/ptp4l -f /etc/linuxptp/ocudu-ptp4l.conf -i ${rif} -m
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/ocudu-phc2sys.service <<EOF
[Unit]
Description=OCUDU phc2sys (PHC -> system clock)
After=ocudu-ptp4l.service
Requires=ocudu-ptp4l.service
[Service]
ExecStart=/usr/sbin/phc2sys -s ${rif} -w -m -R 8
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ocudu-ptp4l.service ocudu-phc2sys.service 2>/dev/null \
    && ok "PTP services started (check sync: journalctl -u ocudu-ptp4l -f ; rms < 10)" \
    || warn "Could not start PTP services - verify ptp4l/phc2sys are installed and ${PTP_IFNAME} supports HW timestamping (ethtool -T ${PTP_IFNAME})."
}

# ----------------------------------------------------------------------------
# PHASE: configs - generate CU (ocu) + DU (odu) YAML and systemd services
# ----------------------------------------------------------------------------
phase_configs() {
  banner "PHASE configs (CU/DU YAML + systemd services)"
  local cfgdir="/etc/ocudu"
  mkdir -p "$cfgdir"

  # --- CU config (CU-CP + CU-UP). N2->AMF, F1 over loopback to the DU. ---
  # CORE_MODE=local -> N2/N3 bind to the docker-bridge host IP (GNB_N2_BIND);
  # CORE_MODE=external -> bind to the physical NG IP. Both come from config.env.
  cat >"${cfgdir}/cu.yml" <<EOF
# OCUDU CU (ocu) - CU-CP + CU-UP. Generated by install.sh (CORE_MODE=${CORE_MODE}).
cu_cp:
  amf:
    addr: ${AMF_ADDR}            # AMF N2 address (5G core)
    bind_addr: ${GNB_N2_BIND}    # local IP the gNB binds for N2/NGAP
    supported_tracking_areas:
      - tac: ${TAC}
        plmn_list:
          - plmn: "${PLMN}"
            tai_slice_support_list:
              - sst: 1
  f1ap:
    bind_addr: ${F1_CU_BIND}     # F1-C bind (loopback - CU/DU co-located)
cu_up:
  f1u:
    socket:
      - bind_addr: ${F1_CU_BIND} # F1-U bind (loopback)
  ngu:
    socket:
      - bind_addr: ${GNB_N3_BIND} # N3 / NG-U (GTP-U) bind toward the UPF

log:
  all_level: ${LOG_LEVEL}
EOF
  ok "Wrote ${cfgdir}/cu.yml (AMF ${AMF_ADDR}, bind ${GNB_N2_BIND})"

  # --- DU config. F1 to CU over loopback, fronthaul over OFH (split 7.2). ---
  local fhvf; fhvf="$(fh_vf_pci)"
  cat >"${cfgdir}/du.yml" <<EOF
# OCUDU DU (odu) - split 7.2 over Open Fronthaul. Generated by install.sh.
f1ap:
  cu_cp_addr: ${F1_CU_BIND}      # CU-CP F1-C address (loopback)
  bind_addr: ${F1_DU_BIND}
f1u:
  socket:
    - bind_addr: ${F1_DU_BIND}

ru_ofh:
  ru_bandwidth_MHz: ${CHANNEL_BW_MHZ}
  # OFH timing windows (min/max, nanoseconds-ish units) - RU-specific, tune per
  # your O-RU's integration guide. These are the OCUDU reference defaults.
  t1a_max_cp_dl: 470
  t1a_min_cp_dl: 258
  t1a_max_cp_ul: 470
  t1a_min_cp_ul: 258
  t1a_max_up: 300
  t1a_min_up: 85
  ta4_max: 500
  ta4_min: 85
  is_prach_cp_enabled: true
  compr_method_ul: bfp
  compr_bitwidth_ul: 9
  compr_method_dl: bfp
  compr_bitwidth_dl: 9
  compr_method_prach: bfp
  compr_bitwidth_prach: 9
  enable_ul_static_compr_hdr: true
  enable_dl_static_compr_hdr: true
  iq_scaling: ${RU_IQ_SCALING}
  cells:
    - network_interface: ${fhvf}          # DPDK PCI of the FH VF (mlx5 PMD, bifurcated)
      ru_mac_addr: ${FH_RU_MAC}           # O-RU fronthaul MAC
      du_mac_addr: ${FH_DU_MAC}           # this DU's fronthaul (VF) MAC
      vlan_tag_cp: ${FH_VLAN}
      vlan_tag_up: ${FH_VLAN}
      prach_port_id: ${RU_PRACH_PORT_ID}  # eAxC IDs - must match the RU
      dl_port_id: ${RU_DL_PORT_ID}        # len must equal nof_antennas_dl
      ul_port_id: ${RU_UL_PORT_ID}        # len must equal nof_antennas_ul

cell_cfg:
  dl_arfcn: ${DL_ARFCN}
  band: ${NR_BAND}
  channel_bandwidth_MHz: ${CHANNEL_BW_MHZ}
  common_scs: ${COMMON_SCS}
  plmn: "${PLMN}"
  tac: ${TAC}
  pci: ${PCI}
  nof_antennas_dl: ${NOF_ANTENNAS_DL}
  nof_antennas_ul: ${NOF_ANTENNAS_UL}

log:
  all_level: ${LOG_LEVEL}
EOF

  # --- CPU pinning: put OCUDU threads ONTO the isolated cores (4-71). ---
  if [[ "${RAN_PIN_CPUS}" == "true" ]]; then
    cat >>"${cfgdir}/du.yml" <<EOF

# Thread pinning onto isolated cores (isolcpus=${ISOLATED_CPUS}). Starting point
# for one 100 MHz cell - refine if OFH reports late/dropped packets.
expert_execution:
  affinities:
    ofh:
      - timing_cpu: ${RAN_OFH_TIMING_CPU}
        txrx_cpus:
          - "${RAN_OFH_TXRX_CPUS}"
  cell_affinities:
    - ru_cpus: ${RAN_RU_CPUS}
  threads:
    lower_phy:
      execution_profile: triple
  main_pool:
    nof_threads: ${RAN_MAIN_POOL_THREADS}
EOF
    ok "Wrote ${cfgdir}/du.yml (CPU pinning: timing=${RAN_OFH_TIMING_CPU} txrx=${RAN_OFH_TXRX_CPUS} ru=${RAN_RU_CPUS})"
  else
    ok "Wrote ${cfgdir}/du.yml (CPU auto-placement; RAN_PIN_CPUS=false)"
  fi

  # --- systemd services for CU then DU (correct start ordering) ---
  local ocu="${OCUDU_DIR}/build/apps/ocu/ocu"
  local odu="${OCUDU_DIR}/build/apps/du/odu"
  [[ -x /usr/local/bin/ocu ]] && ocu=/usr/local/bin/ocu
  [[ -x /usr/local/bin/odu ]] && odu=/usr/local/bin/odu

  cat >/etc/systemd/system/ocudu-cu.service <<EOF
[Unit]
Description=OCUDU CU (ocu)
After=network-online.target ocudu-phc2sys.service
[Service]
ExecStart=${ocu} -c ${cfgdir}/cu.yml
Restart=on-failure
RestartSec=3
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/ocudu-du.service <<EOF
[Unit]
Description=OCUDU DU (odu)
After=ocudu-cu.service ocudu-phc2sys.service
Requires=ocudu-cu.service
[Service]
ExecStart=${odu} -c ${cfgdir}/du.yml
Restart=on-failure
RestartSec=3
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Created systemd services: ocudu-cu.service, ocudu-du.service"
  log  "Enable at boot with:  systemctl enable --now ocudu-cu ocudu-du"
  mark_done configs
  ok "configs phase complete."
}

# ----------------------------------------------------------------------------
# PHASE: verify - light end-to-end sanity checks
# ----------------------------------------------------------------------------
phase_verify() {
  banner "PHASE verify"
  command -v nvidia-smi >/dev/null && nvidia-smi -L || warn "nvidia-smi unavailable."
  command -v nvcc >/dev/null && nvcc --version | tail -1 || warn "nvcc unavailable (open a new shell to load /etc/profile.d/cuda.sh)."
  grep -q HugePages_Total /proc/meminfo && grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo || true
  ethtool -T "${FH_IFNAME}" 2>/dev/null | grep -i 'hardware-transmit\|PTP' || warn "Check HW timestamping on ${FH_IFNAME}."
  [[ -x "${OCUDU_DIR}/build/apps/ocu/ocu" ]] && ok "CU binary present." || warn "CU binary missing."
  [[ -x "${OCUDU_DIR}/build/apps/du/odu" ]] && ok "DU binary present." || warn "DU binary missing."
  systemctl is-active --quiet ocudu-ptp4l && ok "ptp4l running." || warn "ptp4l not active."
  ok "verify complete. Start the stack with: systemctl start ocudu-cu ocudu-du"
}

# ----------------------------------------------------------------------------
# dispatcher
# ----------------------------------------------------------------------------
ALL_PHASES=(host-prep drivers doca tuning docker aerial ocudu network configs verify)

run_phase() {
  case "$1" in
    host-prep) phase_host_prep ;;
    drivers)   phase_drivers ;;
    doca)      phase_doca ;;
    tuning)    phase_tuning ;;
    docker)    phase_docker ;;
    aerial)    phase_aerial ;;
    ocudu)     phase_ocudu ;;
    network)   phase_network ;;
    configs)   phase_configs ;;
    verify)    phase_verify ;;
    *) die "Unknown phase: $1 (see --list)" ;;
  esac
}

usage() {
  cat <<EOF
OCUDU + NVIDIA Aerial 26-1 installer for HPE DL384 Gen12 (GH200)

Usage: sudo $0 [options] [phase ...]

Options:
  --show-nics    List NICs / ConnectX adapters / DPDK bindings and exit
  --show-cpu     Show CPU topology (to choose isolated cores) and exit
  --list         List installation phases and exit
  -h, --help     This help

Phases (run in this order for a fresh box):
  ${ALL_PHASES[*]}

Examples:
  sudo $0 all
  sudo $0 host-prep drivers doca tuning   # then reboot
  sudo $0 docker aerial ocudu network configs verify
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list) printf '%s\n' "${ALL_PHASES[@]}"; exit 0 ;;
  esac
  require_root
  : >"$LOG_FILE" 2>/dev/null || true
  case "${1:-}" in
    --show-nics) preflight; show_nics; exit 0 ;;
    --show-cpu)  show_cpu; exit 0 ;;
  esac

  preflight
  local phases=()
  if [[ "${1:-}" == "all" || $# -eq 0 ]]; then
    phases=("${ALL_PHASES[@]}")
  else
    phases=("$@")
  fi
  log "Running phases: ${phases[*]}"
  for p in "${phases[@]}"; do run_phase "$p"; done
  banner "DONE"
  ok "Completed: ${phases[*]}"
  warn "If any phase printed 'REBOOT', reboot now and re-run the remaining phases."
}

main "$@"
