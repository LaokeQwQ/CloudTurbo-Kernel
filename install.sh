#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="LaokeQwQ"
REPO="CloudTurbo-Kernel"
API_BASE="https://api.github.com/repos/${OWNER}/${REPO}"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh"
WORK_DIR="${WORK_DIR:-/tmp/cloudturbo-kernel-installer}"
SYSCTL_FILE="/etc/sysctl.d/99-cloudturbo-tcp.conf"
DEFAULT_MIRROR_PREFIX="https://gh-proxy.org/"
LANGUAGE="${CLOUDTURBO_LANG:-}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

is_zh() { [[ "${LANGUAGE:-en}" == "zh" || "${LANGUAGE:-en}" == "zh-CN" ]]; }
msg() { if is_zh; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
info() { blue "$(msg "$1" "$2")" >&2; }
ok() { green "$(msg "$1" "$2")" >&2; }
warn() { yellow "$(msg "$1" "$2")" >&2; }
fail() { red "$(msg "$1" "$2")" >&2; }

choose_language() {
  case "${LANGUAGE:-}" in
    en|zh|zh-CN) return 0 ;;
  esac
  if [[ ! -t 0 ]]; then
    LANGUAGE="en"
    return 0
  fi
  printf '\nSelect language / 选择语言\n  1) English\n  2) 简体中文\n'
  local choice
  read -r -p 'Choice / 请选择 [1]: ' choice || true
  case "${choice:-1}" in
    2|zh|ZH|cn|CN|中文) LANGUAGE="zh" ;;
    *) LANGUAGE="en" ;;
  esac
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "This command must be run as root. Try: sudo bash install.sh" "此命令必须以 root 身份运行。请尝试：sudo bash install.sh"
    exit 1
  fi
}

is_debian_like() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  [[ "${ID:-}" =~ ^(debian|ubuntu)$ || " ${ID_LIKE:-} " == *" debian "* ]]
}

ensure_runtime_packages() {
  need_root
  if ! is_debian_like; then
    fail "CloudTurbo installer currently supports Debian/Ubuntu-like systems only." "CloudTurbo 安装脚本目前仅支持 Debian/Ubuntu 系系统。"
    exit 1
  fi
  local packages=(ca-certificates curl python3 dpkg-dev apt-transport-https gnupg lsb-release)
  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Required runtime packages are already installed." "所需运行依赖已安装。"
    return 0
  fi
  warn "Installing missing runtime packages: ${missing[*]}" "正在安装缺失依赖：${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

arch_deb() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) fail "Unsupported architecture: $(uname -m)" "不支持的架构：$(uname -m)"; exit 1 ;;
  esac
}

ask_yes_no() {
  local en="$1"
  local zh="$2"
  local default="${3:-N}"
  local answer suffix
  suffix="[y/N]"
  [[ "$default" == "Y" ]] && suffix="[Y/n]"
  read -r -p "$(msg "$en" "$zh") $suffix " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

configure_mirror() {
  MIRROR_PREFIX=""
  if ask_yes_no "Use a GitHub mirror/proxy before downloading assets?" "下载前是否使用 GitHub 镜像/代理？" "N"; then
    read -r -p "$(msg 'Mirror prefix' '镜像前缀') [${DEFAULT_MIRROR_PREFIX}] " MIRROR_PREFIX || true
    MIRROR_PREFIX="${MIRROR_PREFIX:-$DEFAULT_MIRROR_PREFIX}"
    MIRROR_PREFIX="${MIRROR_PREFIX%/}/"
    warn "Download mirror enabled: ${MIRROR_PREFIX}<original-url>" "已启用下载镜像：${MIRROR_PREFIX}<原始URL>"
    warn "Example: ${MIRROR_PREFIX}${RAW_INSTALL_URL}" "示例：${MIRROR_PREFIX}${RAW_INSTALL_URL}"
  fi
}

mirror_url() {
  local url="$1"
  if [[ -n "${MIRROR_PREFIX:-}" ]]; then
    printf '%s%s\n' "$MIRROR_PREFIX" "$url"
  else
    printf '%s\n' "$url"
  fi
}

curl_json() {
  local url="$1"
  curl -fsSL -H "Accept: application/vnd.github+json" "$url"
}

list_releases() {
  local deb_arch="$1"
  curl_json "${API_BASE}/releases?per_page=100" | python3 -c '
import json, sys
arch = sys.argv[1]
try:
    releases = json.load(sys.stdin)
except Exception as exc:
    print(f"Failed to parse GitHub releases JSON: {exc}", file=sys.stderr)
    sys.exit(2)
rows = []
for rel in releases:
    if rel.get("draft"):
        continue
    assets = rel.get("assets", [])
    debs = [a for a in assets if a.get("name", "").endswith(".deb")]
    arch_debs = [a for a in debs if f"_{arch}.deb" in a.get("name", "") or "_all.deb" in a.get("name", "")]
    if not arch_debs:
        continue
    rows.append((rel.get("tag_name", ""), rel.get("name") or rel.get("tag_name", ""), rel.get("published_at", ""), len(arch_debs)))
if not rows:
    sys.exit(4)
for i, row in enumerate(rows, 1):
    print("\t".join([str(i), *map(str, row)]))
' "$deb_arch"
}

select_release() {
  local deb_arch="$1"
  local release_table rc choice
  set +e
  release_table="$(list_releases "$deb_arch")"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$release_table" ]]; then
    fail "No compiled CloudTurbo Kernel release assets were found for ${deb_arch}." "没有找到适用于 ${deb_arch} 的已编译 CloudTurbo Kernel 版本。"
    warn "Build one first from GitHub Actions: Build Kernel -> build_debs=true -> publish_release=true." "请先在 GitHub Actions 中构建：Build Kernel -> build_debs=true -> publish_release=true。"
    exit 1
  fi

  info "Available CloudTurbo Kernel releases for ${deb_arch}:" "适用于 ${deb_arch} 的 CloudTurbo Kernel 已编译版本："
  printf '%s\n' "$release_table" | awk -F '\t' '{printf "  %2s) %-44s %s assets  %s\n", $1, $2, $5, $4}' >&2
  while true; do
    printf '%s' "$(msg 'Select a release number' '请选择版本编号'): " >&2; read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && printf '%s\n' "$release_table" | awk -F '\t' '{print $1}' | grep -qx "$choice"; then
      printf '%s\n' "$release_table" | awk -F '\t' -v n="$choice" '$1 == n {print $2; exit}'
      return 0
    fi
    warn "Invalid selection." "选择无效。"
  done
}

download_release_assets() {
  local tag="$1"
  local deb_arch="$2"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  configure_mirror
  info "Fetching release metadata: ${tag}" "正在获取版本元数据：${tag}"
  curl_json "${API_BASE}/releases/tags/${tag}" | python3 -c '
import json, sys
arch = sys.argv[1]
rel = json.load(sys.stdin)
for asset in rel.get("assets", []):
    name = asset.get("name", "")
    if not name.endswith(".deb"):
        continue
    if f"_{arch}.deb" not in name and "_all.deb" not in name:
        continue
    print("{}\t{}".format(name, asset.get("browser_download_url", "")))
' "$deb_arch" > "${WORK_DIR}/assets.tsv"
  if [[ ! -s "${WORK_DIR}/assets.tsv" ]]; then
    fail "Release ${tag} has no .deb assets for ${deb_arch}." "版本 ${tag} 没有适用于 ${deb_arch} 的 .deb 文件。"
    exit 1
  fi
  info "Downloading packages into ${WORK_DIR}:" "正在下载软件包到 ${WORK_DIR}："
  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue
    local final_url
    final_url="$(mirror_url "$url")"
    printf '  - %s\n' "$name" >&2
    curl -fL --retry 5 --retry-delay 2 -o "${WORK_DIR}/${name}" "$final_url"
  done < "${WORK_DIR}/assets.tsv"
}

installed_kernel_versions_from_debs() {
  local deb pkg
  for deb in "$WORK_DIR"/*.deb; do
    [[ -f "$deb" ]] || continue
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    case "$pkg" in
      linux-image-*) printf '%s\n' "${pkg#linux-image-}" ;;
    esac
  done | sort -u
}

install_downloaded_debs() {
  need_root
  info "Installing downloaded kernel packages..." "正在安装已下载的内核包..."
  dpkg -i "$WORK_DIR"/*.deb || apt-get -f install -y
  local versions
  versions="$(installed_kernel_versions_from_debs)"
  if [[ -z "$versions" ]]; then
    warn "Could not infer installed kernel version from downloaded linux-image packages." "无法从已下载的 linux-image 包推断内核版本。"
  else
    ok "Installed kernel version(s):" "已安装内核版本："
    printf '%s\n' "$versions" | sed 's/^/  - /' >&2
  fi
}

purge_old_kernels() {
  need_root
  local keep_versions="$1"
  local current
  current="$(uname -r)"
  info "Current running kernel: ${current}" "当前运行内核：${current}"
  info "New kernel version(s) to keep:" "将保留的新内核版本："
  printf '%s\n' "$keep_versions" | sed 's/^/  - /' >&2
  if ! ask_yes_no "Purge old kernel packages now? Current and newly installed kernels will be kept." "现在卸载旧内核包吗？会保留当前运行内核和新安装内核。" "Y"; then
    warn "Skipping old kernel purge." "已跳过旧内核卸载。"
    return 0
  fi

  mapfile -t candidates < <(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 'linux-modules-extra-*' 2>/dev/null | grep -E '^linux-(image|headers|modules|modules-extra)-[0-9]' || true)
  local purge=()
  local pkg keep
  for pkg in "${candidates[@]:-}"; do
    keep=false
    [[ "$pkg" == *"$current"* ]] && keep=true
    while IFS= read -r ver; do
      [[ -n "$ver" && "$pkg" == *"$ver"* ]] && keep=true
    done <<< "$keep_versions"
    if [[ "$keep" == false ]]; then
      purge+=("$pkg")
    fi
  done

  if [[ ${#purge[@]} -eq 0 ]]; then
    ok "No old kernel packages to purge." "没有需要卸载的旧内核包。"
    return 0
  fi
  warn "Packages to purge:" "将卸载以下软件包："
  printf '  - %s\n' "${purge[@]}" >&2
  apt-get purge -y "${purge[@]}"
  apt-get autoremove --purge -y
}

update_bootloader() {
  need_root
  info "Regenerating GRUB configuration..." "正在重新生成 GRUB 配置..."
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    if [[ -d /boot/grub2 ]]; then
      grub2-mkconfig -o /boot/grub2/grub.cfg
    else
      grub2-mkconfig -o /boot/grub/grub.cfg
    fi
  else
    fail "No GRUB update command found. Please update bootloader manually." "未找到 GRUB 更新命令，请手动更新引导配置。"
    exit 1
  fi
}

check_installed_kernel() {
  local versions="$1"
  local missing=0
  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    if [[ -f "/boot/vmlinuz-${ver}" ]]; then
      ok "Found /boot/vmlinuz-${ver}" "已找到 /boot/vmlinuz-${ver}"
    else
      fail "Missing /boot/vmlinuz-${ver}" "缺少 /boot/vmlinuz-${ver}"
      missing=1
    fi
  done <<< "$versions"
  return "$missing"
}

reboot_prompt() {
  if ask_yes_no "Reboot now to start CloudTurbo Kernel?" "现在重启以进入 CloudTurbo Kernel 吗？" "Y"; then
    info "Rebooting..." "正在重启..."
    reboot
  else
    warn "Reboot skipped. Boot into the new kernel before enabling TCP features." "已跳过重启。启用 TCP 特性前请先启动进入新内核。"
  fi
}

install_kernel_flow() {
  need_root
  ensure_runtime_packages
  local deb_arch tag versions
  deb_arch="$(arch_deb)"
  tag="$(select_release "$deb_arch")"
  warn "Selected release: ${tag}" "已选择版本：${tag}"
  download_release_assets "$tag" "$deb_arch"
  install_downloaded_debs
  versions="$(installed_kernel_versions_from_debs)"
  purge_old_kernels "$versions"
  update_bootloader
  check_installed_kernel "$versions"
  reboot_prompt
}

available_cc() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }

try_load_cc_modules() {
  modprobe tcp_bbrplus 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  modprobe brutal 2>/dev/null || true
  modprobe tcp_brutal 2>/dev/null || true
}

enable_tcp_features() {
  need_root
  try_load_cc_modules
  local cc_list choices=() cc selected num
  cc_list="$(available_cc)"
  info "Available congestion controls: ${cc_list:-unknown}" "可用拥塞控制算法：${cc_list:-unknown}"
  for cc in bbrplus bbr brutal cubic; do
    if printf '%s\n' "$cc_list" | tr ' ' '\n' | grep -qx "$cc"; then choices+=("$cc"); fi
  done
  if [[ ${#choices[@]} -eq 0 ]]; then
    fail "No supported congestion control found. Is the new kernel running?" "没有找到支持的拥塞控制算法。是否已经重启进入新内核？"
    exit 1
  fi
  info "Select TCP congestion control:" "请选择 TCP 拥塞控制算法："
  local i=1
  for cc in "${choices[@]}"; do
    if [[ "$cc" == "brutal" ]]; then
      printf '  %d) %s (%s)\n' "$i" "$cc" "$(msg 'advanced; only use if your software supports TCP Brutal params' '高级选项；仅在应用支持 TCP Brutal 参数时使用')" >&2
    else
      printf '  %d) %s\n' "$i" "$cc" >&2
    fi
    i=$((i+1))
  done
  while true; do
    read -r -p "$(msg 'Choice [1]' '选择 [1]'): " num
    num="${num:-1}"
    if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#choices[@]} ]]; then
      selected="${choices[$((num-1))]}"
      break
    fi
    warn "Invalid selection." "选择无效。"
  done

  if [[ "$selected" == "brutal" ]]; then
    warn "TCP Brutal is usually application-selected, not a safe global default." "TCP Brutal 通常应由应用选择，不建议作为全局默认值。"
    if ! ask_yes_no "Set brutal as global default anyway?" "仍然将 brutal 设置为全局默认值吗？" "N"; then
      warn "Skipped setting brutal as global default." "已跳过设置 brutal 为全局默认值。"
      return 0
    fi
  fi

  cat > "$SYSCTL_FILE" <<EOF
# CloudTurbo TCP tuning. Generated by CloudTurbo installer.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${selected}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
EOF
  sysctl --system
  ok "Enabled ${selected} with fq pacing." "已启用 ${selected} 和 fq pacing。"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
}

show_status() {
  info "CloudTurbo Kernel status" "CloudTurbo Kernel 状态"
  printf '  %s: %s\n' "$(msg 'Running kernel' '当前内核')" "$(uname -r)"
  printf '  %s: %s (%s)\n' "$(msg 'Architecture' '架构')" "$(uname -m)" "$(arch_deb)"
  printf '  %s: %s\n' "$(msg 'Available CC' '可用拥塞控制')" "$(available_cc)"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  printf '\n%s\n' "$(msg 'Installed kernel images:' '已安装内核镜像：')"
  dpkg-query -W -f='  ${Package}\t${Version}\n' 'linux-image-*' 2>/dev/null | grep -E '^  linux-image-[0-9]' || true
}

menu() {
  while true; do
    if is_zh; then
      cat <<'EOF'

CloudTurbo Kernel 安装器
  1) 从 GitHub Releases 安装/升级 CloudTurbo Kernel
  2) 重启后启用 TCP 加速（可用时启用 BBRPlus/BBR）
  3) 重新生成 GRUB
  4) 查看内核/TCP 状态
  0) 退出
EOF
      read -r -p '请选择操作: ' opt
    else
      cat <<'EOF'

CloudTurbo Kernel installer
  1) Install/upgrade CloudTurbo Kernel from GitHub Releases
  2) Enable TCP acceleration after reboot (BBRPlus/BBR when available)
  3) Regenerate GRUB
  4) Show kernel/TCP status
  0) Exit
EOF
      read -r -p 'Choose an option: ' opt
    fi
    case "$opt" in
      1) install_kernel_flow ;;
      2) enable_tcp_features ;;
      3) update_bootloader ;;
      4) show_status ;;
      0) exit 0 ;;
      *) warn "Invalid option." "选择无效。" ;;
    esac
  done
}

choose_language
case "${1:-menu}" in
  install) install_kernel_flow ;;
  tune|bbr|enable-bbr) enable_tcp_features ;;
  status) show_status ;;
  grub) update_bootloader ;;
  menu) menu ;;
  *)
    cat <<EOF
Usage: $0 [menu|install|tune|status|grub]

Examples:
  bash $0 install
  CLOUDTURBO_LANG=zh bash $0 tune
EOF
    exit 2
    ;;
esac