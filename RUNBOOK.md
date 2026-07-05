# OCUDU first-light ランブック (HPE DL384 / GH200)

Phase 0（ベアメタル）で OCUDU CU+DU を同居 Open5GS に接続し、first light
（UE 疎通）までを通すための手順書。実機 `dl384`（Ubuntu 26.04 / GH200）で
検証済みの内容。

## 0. 構成（何がどこで動くか）

| コンポーネント | 実行形態 | 実体 |
|---|---|---|
| ocu（CU） | ネイティブ / systemd | `ocudu-cu.service` |
| odu（DU） | ネイティブ / systemd | `ocudu-du.service` |
| ptp4l / phc2sys | ネイティブ / systemd | `ocudu-ptp4l` / `ocudu-phc2sys` |
| Open5GS（5Gコア） | Docker | `open5gs_5gc`（同梱 compose） |

ネットワーク割当（ConnectX-7 ×2 = 4ポート + オンボード1GbE）:

| IF | 用途 | 備考 |
|---|---|---|
| `enp1s0f0np0`（0000:01:00.0） | **FH（フロントホール）** | DPDK(mlx5 bifurcated)+PTP。VF `0000:01:00.2` |
| `enp1s0f1np1`（0000:01:00.1） | NG（外部コア時のみ） | 同居コアでは未使用 |
| `enP2s2f0/f1np*`（0002:01:00.x） | 予備 | 2セル目 / 冗長 / 専用PTP |
| `enx04ab18f77160`（onboard 1GbE） | **管理 / SSH** | 10.10.10.161 |

- F1(CU↔DU)/E1 は同居のためループバック（物理ポート不要）。
- 同居コア時は N2/N3 も docker ブリッジ（10.53.1.0/24）経由で、物理NG不要。

---

## 1. 初回セットアップ（済み。再構築時のみ）

```bash
# コード取得
git clone https://github.com/postman-maker/ocudu_Aerial_installation_script.git
cd ocudu_Aerial_installation_script
git checkout claude/pensive-turing-ksesea

# ハード確認（NIC名/PCI/CPU）
sudo ./install.sh --show-nics
sudo ./install.sh --show-cpu

# 第1ラウンド: OS準備 + inbox NICスタック + カーネルチューニング → 要再起動
sudo ./install.sh host-prep doca tuning
sudo reboot

# 再起動後の確認
cat /proc/cmdline | tr ' ' '\n' | grep -E 'hugepages|isolcpus|iommu'
grep -i HugePages_Total /proc/meminfo     # 32 期待
ibv_devices                                # mlx5 4ポート見える

# OCUDU ビルド（ocu/odu）
sudo ./install.sh ocudu

# Docker 導入（Open5GS 用）
sudo ./install.sh docker
```

> ドライバ/Aerial(GPU L1)は first light では不要のため後回し（`drivers`/`aerial`）。

---

## 2. コア + CU 起動（RU なしで到達可能）

```bash
cd ~/ocudu_Aerial_installation_script && git pull

# 5Gコア(Open5GS)起動（NATモジュール自動ロード込み）
sudo ./scripts/core-up.sh up
sudo ./scripts/core-up.sh logs        # AMF: "NGAP server ... 10.53.1.2:38412" 確認 → Ctrl+C

# 設定生成（CORE_MODE=local: AMF=10.53.1.2 / bind=10.53.1.1 / PLMN 00101 / TAC 7）
sudo ./install.sh configs

# CU 起動 → N2 確認
sudo modprobe sctp
sudo systemctl start ocudu-cu
journalctl -u ocudu-cu -f
#   期待: "N2: Connection to AMF on 10.53.1.2:38412 completed"
#         "F1-C: Listening ... 38472"
```

コア側でも `gNB-N2 accepted` / `Number of gNBs is now 1` を確認できる。

---

## 3. RU 接続後: DU 起動 → セル UP

### 3-1. `config.env` を RU 実値に（RU 型番の実例に合わせる）
```bash
# フロントホール / RU
FH_RU_MAC="<O-RUのMAC>"
FH_VLAN="<C/U-plane VLAN>"
PTP_DOMAIN="<T-GM(FHスイッチ)のPTPドメイン>"
RU_IQ_SCALING="1.0"                 # RU依存(例: Picocom/rpqn=1.0, RAN550=5.5)

# アンテナ / eAxC（dl_port_id 要素数 == NOF_ANTENNAS_DL, ul も同様）
NOF_ANTENNAS_DL="1"; NOF_ANTENNAS_UL="1"
RU_DL_PORT_ID="[0]"; RU_UL_PORT_ID="[0]"; RU_PRACH_PORT_ID="[4]"
#   例(4x2 RU): DL=4/UL=2, RU_DL_PORT_ID="[0,1,2,3]" RU_UL_PORT_ID="[0,1]" RU_PRACH_PORT_ID="[4,5]"

# セル / 無線
DL_ARFCN="..."; NR_BAND="78"; CHANNEL_BW_MHZ="100"; COMMON_SCS="30"; PCI="1"
```

### 3-2. 反映 + フロントホール/PTP 起動 + DU 起動
```bash
sudo ./install.sh configs
sudo ./install.sh network            # FH VF作成 + PTP(ptp4l/phc2sys)起動
journalctl -u ocudu-ptp4l -f         # rms < 10 で PTP ロック確認（T-GM必須）

sudo systemctl start ocudu-du
journalctl -u ocudu-du -f
#   期待: OFH初期化 → "Cell pci=..." → "DU started" → F1-C接続
sudo ./scripts/status.sh
```

---

## 4. UE 接続 → 疎通

- 加入者は PLMN 00101 のテストUEがコアに登録済み
  （`/opt/ocudu/docker/open5gs/subscriber_db.csv` / WebUI `http://localhost:9999`）。
- UE を接続し、DU コンソール/ログで MCS・レートを確認。
- UE への疎通: `ping <UE_IP>`（UEプール `10.45.0.0/16` は `10.53.1.2` 経由の route 済み）。

---

## 5. 運用コマンド

```bash
sudo ./scripts/status.sh             # CU/DU/PTP/セル/VF/hugepages 一覧
sudo ./scripts/core-up.sh {up|down|logs|webui}
journalctl -u ocudu-cu -f            # CU ログ
journalctl -u ocudu-du -f            # DU ログ

# 検証後、自動起動を有効化
sudo systemctl enable ocudu-cu ocudu-du
```

- ログレベル: `config.env` の `LOG_LEVEL`（bring-up=`info` / 安定=`warning`）→ `configs` 再実行。
- ライブUEトレース表: サービス停止して前面実行 → `sudo /opt/ocudu/build/apps/du/odu -c /etc/ocudu/du.yml` で `t` キー。

---

## 6. 外部コア（別Open5GS）へ切替（例: 月曜の別コア）

```bash
# config.env
CORE_MODE="external"
EXTERNAL_AMF_ADDR="<実AMFのN2アドレス>"
NG_LOCAL_IP="..."; NG_PREFIX="24"; NG_GATEWAY="..."   # 物理NG(enp1s0f1np1)
```
```bash
sudo ./install.sh configs
sudo ./install.sh network
sudo systemctl restart ocudu-cu
```

---

## 7. トラブルシュート（実際に遭遇した事例）

| 症状 | 原因 / 対処 |
|---|---|
| `apt`/`git` が名前解決失敗（ping IPはOK） | DNS未設定。`resolvectl dns <IF> 8.8.8.8` か `/etc/resolv.conf` |
| CUDA/DOCA リポジトリが 26.04 に無い | `config.env` の `NV_UBUNTU_REPO=ubuntu2404`（設定済み） |
| Open5GS: `iptables who? (do you need to insmod?)` | ホストのNATモジュール未ロード。`core-up.sh up` が自動 modprobe |
| CU: `INI was not able to parse cu_up.gtpu` | N3は `cu_up.ngu.socket` が正（修正済み） |
| DU: `INI ... ru_ofh.t1a_cp_dl` | `t1a_max/min_cp_dl` 等の min/max キーが正（修正済み） |
| DU: `... ru_mac_address` not expected | 実バイナリは `ru_mac_addr`/`du_mac_addr`（修正済み） |
| DU: `expert_execution.affinities.ofh` | ドキュメントとバイナリ差異。ピンニング無効化(`RAN_PIN_CPUS=false`)。カーネル isolcpus は有効 |
| DU: `downlink ports=N must match antennas=M` | `dl_port_id` 要素数と `nof_antennas_dl` を一致させる |
| DU: `Missing IQ scaling configuration` | `ru_ofh.iq_scaling` 必須（`RU_IQ_SCALING`、修正済み） |
| DU: バナー後に無言で停止 | 設定OK。RU未接続でOFH初期化待ち（正常）。`LOG_LEVEL=info` で可視化 |

---

## 8. Phase アップ（後日）

- **B: Docker Compose 化** — `images/Dockerfile.ocudu` で ocu+odu をコンテナ化。
- **C: Kubernetes** — `kubernetes/`（Helm + Multus/SR-IOV/PTP/GPU operator）。
- **Aerial(GPU L1)連携** — `drivers`+`aerial` フェーズ（CUDA 12.9 / Aerial 26-1）。

いずれも first light（RU+UE 疎通）確認後に着手する想定。
