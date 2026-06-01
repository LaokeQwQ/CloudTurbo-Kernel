#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.2.6"
SCRIPT_RELEASE_DATE="2026-06-01"
OWNER="LaokeQwQ"
REPO="CloudTurbo-Kernel"
API_BASE="https://api.github.com/repos/${OWNER}/${REPO}"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh"
SELF_INSTALL_PATH="/usr/local/bin/cloudturbo-kernel"
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

clear_interactive() {
  [[ -t 1 ]] && command -v clear >/dev/null 2>&1 && clear || true
}

header() {
  printf 'CloudTurbo Kernel installer v%s (%s)\n' "$SCRIPT_VERSION" "$SCRIPT_RELEASE_DATE" >&2
  if is_zh; then
    printf 'CloudTurbo Kernel 安装器 v%s（发布于 %s）\n' "$SCRIPT_VERSION" "$SCRIPT_RELEASE_DATE" >&2
  fi
}

pause_prompt() {
  [[ -t 0 ]] || return 0
  read -r -p "$(msg 'Press Enter to continue...' '按 Enter 继续...')" _ || true
}

choose_language() {
  case "${LANGUAGE:-}" in
    en|zh|zh-CN) return 0 ;;
  esac
  if [[ ! -t 0 ]]; then
    LANGUAGE="en"
    return 0
  fi
  clear_interactive
  printf 'CloudTurbo Kernel installer v%s (%s)\n\n' "$SCRIPT_VERSION" "$SCRIPT_RELEASE_DATE"
  printf 'Select language / 选择语言\n  1) English\n  2) 简体中文\n'
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
  local do_clear="${4:-1}"
  local answer suffix
  [[ "$do_clear" == "1" ]] && clear_interactive && header && printf '\n'
  suffix="[y/N]"
  [[ "$default" == "Y" ]] && suffix="[Y/n]"
  read -r -p "$(msg "$en" "$zh") $suffix " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

configure_mirror() {
  MIRROR_PREFIX=""
  clear_interactive
  header
  printf '\n'
  if ask_yes_no "Use a GitHub mirror/proxy before downloading assets?" "下载前是否使用 GitHub 镜像/代理？" "N" "0"; then
    read -r -p "$(msg 'Mirror prefix' '镜像前缀') [${DEFAULT_MIRROR_PREFIX}] " MIRROR_PREFIX || true
    MIRROR_PREFIX="${MIRROR_PREFIX:-$DEFAULT_MIRROR_PREFIX}"
    MIRROR_PREFIX="${MIRROR_PREFIX%/}/"
    warn "Download mirror enabled: ${MIRROR_PREFIX}<original-url>" "已启用下载镜像：${MIRROR_PREFIX}<原始URL>"
    warn "Example: ${MIRROR_PREFIX}${RAW_INSTALL_URL}" "示例：${MIRROR_PREFIX}${RAW_INSTALL_URL}"
    pause_prompt
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
    if rel.get("draft") or rel.get("prerelease"):
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
  clear_interactive
  header
  printf '\n' >&2
  if [[ $rc -ne 0 || -z "$release_table" ]]; then
    fail "No compiled CloudTurbo Kernel release assets were found for ${deb_arch}." "没有找到适用于 ${deb_arch} 的已编译 CloudTurbo Kernel 版本。"
    warn "Build one first from GitHub Actions: Build Kernel -> build_debs=true -> publish_release=true." "请先在 GitHub Actions 中构建：Build Kernel -> build_debs=true -> publish_release=true。"
    exit 1
  fi

  info "Available CloudTurbo Kernel releases for ${deb_arch}:" "适用于 ${deb_arch} 的 CloudTurbo Kernel 已编译版本："
  printf '%s\n' "$release_table" | awk -F '\t' '{printf "  %2s) %-44s %s assets  %s\n", $1, $2, $5, $4}' >&2
  while true; do
    printf '%s' "$(msg 'Select a release number' '请选择版本编号'): " >&2
    read -r choice
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
  clear_interactive
  header
  printf '\n'
  info "Fetching release metadata: ${tag}" "正在获取版本元数据：${tag}"
  curl_json "${API_BASE}/releases/tags/${tag}" | python3 -c '
import json, sys
arch = sys.argv[1]
rel = json.load(sys.stdin)
checksum_names = {
    f"MD5SUMS-{arch}.txt",
    f"SHA1SUMS-{arch}.txt",
    f"SHA256SUMS-{arch}.txt",
    f"SHA512SUMS-{arch}.txt",
}
for asset in rel.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(".deb"):
        if f"_{arch}.deb" not in name and "_all.deb" not in name:
            continue
    elif name not in checksum_names:
        continue
    print("{}\t{}".format(name, asset.get("browser_download_url", "")))
' "$deb_arch" > "${WORK_DIR}/assets.tsv"
  if ! awk -F '\t' '$1 ~ /\.deb$/ {found=1} END {exit found ? 0 : 1}' "${WORK_DIR}/assets.tsv"; then
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
verify_downloaded_assets() {
  local deb_arch="$1"
  local file
  local failed=0
  shopt -s nullglob
  local debs=( "$WORK_DIR"/*.deb )
  if [[ ${#debs[@]} -eq 0 ]]; then
    fail "No downloaded .deb packages found." "没有找到已下载的 .deb 内核包。"
    exit 1
  fi
  for file in "MD5SUMS-${deb_arch}.txt" "SHA1SUMS-${deb_arch}.txt" "SHA256SUMS-${deb_arch}.txt" "SHA512SUMS-${deb_arch}.txt"; do
    if [[ ! -s "$WORK_DIR/$file" ]]; then
      fail "Missing checksum manifest: ${file}" "缺少校验清单：${file}"
      warn "Please choose a newer CloudTurbo release or rebuild it with checksum publishing enabled." "请选择更新的 CloudTurbo 版本，或重新构建并启用校验值发布。"
      exit 1
    fi
  done
  info "Verifying downloaded package checksums..." "正在校验已下载内核包的完整性..."
  if ! (cd "$WORK_DIR" && md5sum -c "MD5SUMS-${deb_arch}.txt") >&2; then
    failed=1
  fi
  if ! (cd "$WORK_DIR" && sha1sum -c "SHA1SUMS-${deb_arch}.txt") >&2; then
    failed=1
  fi
  if ! (cd "$WORK_DIR" && sha256sum -c "SHA256SUMS-${deb_arch}.txt") >&2; then
    failed=1
  fi
  if ! (cd "$WORK_DIR" && sha512sum -c "SHA512SUMS-${deb_arch}.txt") >&2; then
    failed=1
  fi
  if [[ "$failed" == "1" ]]; then
    fail "Checksum verification failed. One or more downloaded kernel packages do not match the release manifests." "校验值验证失败：一个或多个已下载内核包与发布清单不一致。"
    warn "Possible causes: broken release assets, mirror/proxy corruption, interrupted download, or tampering." "可能原因：Release 资源错误、镜像/代理污染、下载中断或文件被篡改。"
    if [[ "${CLOUDTURBO_IGNORE_CHECKSUM:-0}" == "1" ]] || ask_yes_no "Ignore checksum failure and continue installing at your own risk?" "是否忽略校验失败并自担风险继续安装？" "N" "1"; then
      warn "Continuing despite checksum failure by user request." "已按用户选择忽略校验失败并继续。"
      return 0
    fi
    fail "Installation aborted because checksum verification failed." "已因校验失败中止安装。"
    exit 1
  fi
  ok "Checksum verification passed." "校验值验证通过。"
}
kernel_package_versions_from_debs() {
  local deb pkg
  for deb in "$WORK_DIR"/*.deb; do
    [[ -f "$deb" ]] || continue
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    case "$pkg" in
      linux-image-*) printf '%s\n' "${pkg#linux-image-}" ;;
    esac
  done | sort -u
}

boot_kernel_versions_from_debs() {
  local deb versions
  versions="$(
    for deb in "$WORK_DIR"/linux-image-*.deb; do
      [[ -f "$deb" ]] || continue
      dpkg-deb -c "$deb" 2>/dev/null \
        | awk '{print $NF}' \
        | sed -n \
            -e 's#^\./boot/vmlinuz-##p' \
            -e 's#^\./lib/modules/\([^/][^/]*\)/.*#\1#p' \
            -e 's#^\./usr/lib/modules/\([^/][^/]*\)/.*#\1#p'
    done | sort -u
  )"
  if [[ -n "$versions" ]]; then
    printf '%s\n' "$versions" | tee "${WORK_DIR}/boot-kernel-versions.txt"
  else
    kernel_package_versions_from_debs
  fi
}

installed_cloudturbo_boot_versions() {
  find /boot -maxdepth 1 -type f -name 'vmlinuz-*cloudturbo*' -printf '%f\n' 2>/dev/null \
    | sed 's#^vmlinuz-##' \
    | sort -Vu
}

install_downloaded_debs() {
  need_root
  info "Installing downloaded kernel packages..." "正在安装已下载的内核包..."
  dpkg -i "$WORK_DIR"/*.deb || apt-get -f install -y
  local boot_versions package_versions
  boot_versions="$(boot_kernel_versions_from_debs)"
  package_versions="$(kernel_package_versions_from_debs)"
  if [[ -z "$boot_versions" ]]; then
    warn "Could not infer installed boot kernel version from downloaded linux-image packages." "无法从已下载的 linux-image 包推断实际启动内核版本。"
  else
    ok "Installed boot kernel version(s):" "已安装启动内核版本："
    printf '%s\n' "$boot_versions" | sed 's/^/  - /' >&2
  fi
  if [[ -n "$package_versions" && "$package_versions" != "$boot_versions" ]]; then
    info "Installed kernel package version(s):" "已安装内核包版本："
    printf '%s\n' "$package_versions" | sed 's/^/  - /' >&2
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
  clear_interactive
  header
  printf '\n'
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
  local detected
  detected="$(installed_cloudturbo_boot_versions)"
  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    if [[ -f "/boot/vmlinuz-${ver}" ]]; then
      ok "Found /boot/vmlinuz-${ver}" "已找到 /boot/vmlinuz-${ver}"
    else
      fail "Missing /boot/vmlinuz-${ver}" "缺少 /boot/vmlinuz-${ver}"
      missing=1
    fi
  done <<< "$versions"
  if [[ "$missing" == "1" && -n "$detected" ]]; then
    warn "Expected kernel name did not match package metadata, but CloudTurbo kernel image(s) exist under /boot:" "期望的内核文件名与包元数据不一致，但 /boot 下已存在 CloudTurbo 内核镜像："
    printf '%s\n' "$detected" | sed 's#^#  - /boot/vmlinuz-#' >&2
    return 0
  fi
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
  local deb_arch tag boot_versions package_versions keep_versions
  deb_arch="$(arch_deb)"
  tag="$(select_release "$deb_arch" | awk 'NF {last=$0} END {print last}')"
  tag="$(printf '%s' "$tag" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ ! "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "Invalid release tag selected: ${tag}" "选择到的版本 tag 无效：${tag}"
    exit 1
  fi
  warn "Selected release: ${tag}" "已选择版本：${tag}"
  download_release_assets "$tag" "$deb_arch"
  verify_downloaded_assets "$deb_arch"
  install_downloaded_debs
  boot_versions="$(boot_kernel_versions_from_debs)"
  package_versions="$(kernel_package_versions_from_debs)"
  keep_versions="$(printf '%s\n%s\n' "$boot_versions" "$package_versions" | sed '/^$/d' | sort -u)"
  purge_old_kernels "$keep_versions"
  update_bootloader
  check_installed_kernel "$boot_versions"
  reboot_prompt
}

available_cc() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }

cc_is_available() {
  local cc_list="$1"
  local cc="$2"
  printf '%s\n' "$cc_list" | tr ' ' '\n' | grep -qx "$cc"
}

try_load_cc_modules() {
  modprobe tcp_bbrplus 2>/dev/null || true
  modprobe tcp_bbr2 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  modprobe brutal 2>/dev/null || true
  modprobe tcp_brutal 2>/dev/null || true
}

verify_tcp_strategy() {
  local selected="$1"
  local cc_list actual_cc actual_qdisc
  try_load_cc_modules
  cc_list="$(available_cc)"
  if ! cc_is_available "$cc_list" "$selected"; then
    fail "Selected congestion control is no longer available: ${selected}" "选中的拥塞控制当前不可用：${selected}"
    warn "Available congestion controls: ${cc_list:-unknown}" "当前可用拥塞控制：${cc_list:-unknown}"
    exit 1
  fi

  info "Applying and verifying TCP strategy: ${selected} + fq" "正在应用并验证 TCP 策略：${selected} + fq"
  sysctl --system
  actual_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  actual_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [[ "$actual_cc" != "$selected" || "$actual_qdisc" != "fq" ]]; then
    fail "TCP strategy did not fully take effect." "TCP 策略未完全生效。"
    warn "Expected: tcp_congestion_control=${selected}, default_qdisc=fq" "期望值：tcp_congestion_control=${selected}, default_qdisc=fq"
    warn "Actual:   tcp_congestion_control=${actual_cc:-unknown}, default_qdisc=${actual_qdisc:-unknown}" "实际值：tcp_congestion_control=${actual_cc:-unknown}, default_qdisc=${actual_qdisc:-unknown}"
    warn "Check for conflicting sysctl files that override ${SYSCTL_FILE}." "请检查是否有其他 sysctl 配置覆盖了 ${SYSCTL_FILE}。"
    exit 1
  fi
  ok "TCP strategy is active: ${selected} + fq" "TCP 策略已完全生效：${selected} + fq"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
}

enable_tcp_features() {
  need_root
  local requested="${1:-}"
  clear_interactive
  header
  printf '\n'
  try_load_cc_modules
  local cc_list choices=() cc selected num
  cc_list="$(available_cc)"
  info "Available congestion controls: ${cc_list:-unknown}" "可用拥塞控制算法：${cc_list:-unknown}"
  for cc in bbrplus bbr2 bbr brutal cubic; do
    if cc_is_available "$cc_list" "$cc"; then choices+=("$cc"); fi
  done
  if [[ ${#choices[@]} -eq 0 ]]; then
    fail "No supported congestion control found. Is the new kernel running?" "没有找到支持的拥塞控制算法。是否已经重启进入新内核？"
    exit 1
  fi

  if [[ -n "$requested" ]]; then
    case "$requested" in
      bbrplus|bbr2|bbr|brutal|cubic) ;;
      *) fail "Unsupported TCP strategy request: ${requested}" "不支持的 TCP 策略请求：${requested}"; exit 1 ;;
    esac
    if ! cc_is_available "$cc_list" "$requested"; then
      fail "Requested congestion control is not available: ${requested}" "请求的拥塞控制当前不可用：${requested}"
      warn "Available congestion controls: ${cc_list:-unknown}" "当前可用拥塞控制：${cc_list:-unknown}"
      exit 1
    fi
    selected="$requested"
    ok "Selected TCP strategy: ${selected}" "已选择 TCP 策略：${selected}"
  else
    info "Select TCP congestion control:" "请选择 TCP 拥塞控制算法："
    local i=1
    for cc in "${choices[@]}"; do
      case "$cc" in
        bbrplus) printf '  %d) %s (%s)\n' "$i" "$cc" "$(msg 'BBRPlus' 'BBRPlus')" >&2 ;;
        bbr2) printf '  %d) %s (%s)\n' "$i" "$cc" "$(msg 'BBRv2/BBR2 when provided by the running kernel' '当前内核提供的 BBRv2/BBR2')" >&2 ;;
        bbr) printf '  %d) %s (%s)\n' "$i" "$cc" "$(msg 'BBR/BBRv3 when provided as bbr by the running kernel' '当前内核以 bbr 暴露的 BBR/BBRv3')" >&2 ;;
        brutal) printf '  %d) %s (%s)\n' "$i" "$cc" "$(msg 'advanced; only use if your software supports TCP Brutal params' '高级选项；仅在应用支持 TCP Brutal 参数时使用')" >&2 ;;
        *) printf '  %d) %s\n' "$i" "$cc" >&2 ;;
      esac
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
  fi

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
  verify_tcp_strategy "$selected"
}
show_status() {
  clear_interactive
  header
  printf '\n'
  info "CloudTurbo Kernel status" "CloudTurbo Kernel 状态"
  printf '  %s: %s\n' "$(msg 'Running kernel' '当前内核')" "$(uname -r)"
  printf '  %s: %s (%s)\n' "$(msg 'Architecture' '架构')" "$(uname -m)" "$(arch_deb)"
  printf '  %s: %s\n' "$(msg 'Available CC' '可用拥塞控制')" "$(available_cc)"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  printf '\n%s\n' "$(msg 'Installed kernel images:' '已安装内核镜像：')"
  dpkg-query -W -f='  ${Package}\t${Version}\n' 'linux-image-*' 2>/dev/null | grep -E '^  linux-image-[0-9]' || true
  pause_prompt
}

script_source_path() {
  local src="${BASH_SOURCE[0]}"
  if [[ -n "$src" && -f "$src" && -w "$src" ]]; then
    readlink -f "$src" 2>/dev/null || printf '%s\n' "$src"
  else
    printf '%s\n' "$SELF_INSTALL_PATH"
  fi
}

extract_remote_meta() {
  local file="$1"
  local remote_version remote_date
  remote_version="$(grep -E '^SCRIPT_VERSION=' "$file" | head -n1 | cut -d= -f2- | tr -d '"')"
  remote_date="$(grep -E '^SCRIPT_RELEASE_DATE=' "$file" | head -n1 | cut -d= -f2- | tr -d '"')"
  printf '%s\t%s\n' "$remote_version" "$remote_date"
}

self_update() {
  need_root
  clear_interactive
  header
  printf '\n'
  configure_mirror
  mkdir -p "$WORK_DIR"
  local tmp target final_url meta remote_version remote_date
  tmp="${WORK_DIR}/install.sh.new"
  final_url="$(mirror_url "$RAW_INSTALL_URL")"
  info "Downloading latest installer script..." "正在下载最新安装脚本..."
  curl -fL --retry 5 --retry-delay 2 -o "$tmp" "$final_url"
  chmod +x "$tmp"
  meta="$(extract_remote_meta "$tmp")"
  remote_version="${meta%%$'\t'*}"
  remote_date="${meta#*$'\t'}"
  info "Current script: v${SCRIPT_VERSION} (${SCRIPT_RELEASE_DATE})" "当前脚本：v${SCRIPT_VERSION}（${SCRIPT_RELEASE_DATE}）"
  info "Remote script:  v${remote_version:-unknown} (${remote_date:-unknown})" "远端脚本：v${remote_version:-unknown}（${remote_date:-unknown}）"
  if [[ "${remote_version:-}" == "$SCRIPT_VERSION" && "${remote_date:-}" == "$SCRIPT_RELEASE_DATE" ]]; then
    if ! ask_yes_no "The installer is already up to date. Reinstall it anyway?" "安装脚本已是最新，仍然重新安装吗？" "N"; then
      warn "Self-update skipped." "已跳过自更新。"
      return 0
    fi
  fi
  target="$(script_source_path)"
  install -m 0755 "$tmp" "$target"
  ok "Installer updated at ${target}." "安装脚本已更新到 ${target}。"
  if [[ "$target" == "$SELF_INSTALL_PATH" ]]; then
    ok "You can run it later with: ${SELF_INSTALL_PATH}" "之后可通过以下命令运行：${SELF_INSTALL_PATH}"
  fi
  if ask_yes_no "Restart the updated installer now?" "现在重新启动新版安装脚本吗？" "Y"; then
    exec "$target" menu
  fi
}

menu() {
  while true; do
    clear_interactive
    header
    if is_zh; then
      cat <<'EOF'

CloudTurbo Kernel 安装器
  1) 从 GitHub Releases 安装/升级 CloudTurbo Kernel
  2) 重启后启用 BBR
  3) 重启后启用 BBRPlus
  4) 重启后启用 BBR2
  5) 交互选择 TCP 策略
  6) 重新生成 GRUB
  7) 查看内核/TCP 状态
  8) 更新安装脚本
  0) 退出
EOF
      read -r -p '请选择操作: ' opt
    else
      cat <<'EOF'

CloudTurbo Kernel installer
  1) Install/upgrade CloudTurbo Kernel from GitHub Releases
  2) Enable BBR after reboot
  3) Enable BBRPlus after reboot
  4) Enable BBR2 after reboot
  5) Select TCP strategy interactively
  6) Regenerate GRUB
  7) Show kernel/TCP status
  8) Update installer script
  0) Exit
EOF
      read -r -p 'Choose an option: ' opt
    fi
    case "$opt" in
      1) install_kernel_flow ;;
      2) enable_tcp_features bbr ;;
      3) enable_tcp_features bbrplus ;;
      4) enable_tcp_features bbr2 ;;
      5) enable_tcp_features ;;
      6) update_bootloader; pause_prompt ;;
      7) show_status ;;
      8) self_update ;;
      0) exit 0 ;;
      *) warn "Invalid option." "选择无效。"; pause_prompt ;;
    esac
  done
}

choose_language
case "${1:-menu}" in
  install) install_kernel_flow ;;
  tune|tcp|enable-tcp) enable_tcp_features ;;
  bbr|bbrplus|bbr2|brutal|cubic) enable_tcp_features "$1" ;;
  enable-bbr) enable_tcp_features bbr ;;
  enable-bbrplus) enable_tcp_features bbrplus ;;
  enable-bbr2) enable_tcp_features bbr2 ;;
  status) show_status ;;
  grub) update_bootloader ;;
  self-update|update|update-script) self_update ;;
  menu) menu ;;
  *)
    cat <<EOF
CloudTurbo Kernel installer v${SCRIPT_VERSION} (${SCRIPT_RELEASE_DATE})
Usage: $0 [menu|install|tune|bbr|bbrplus|bbr2|status|grub|self-update]

Examples:
  bash $0 install
  CLOUDTURBO_LANG=zh bash $0 tune
  sudo $0 bbrplus
  sudo $0 bbr2
  sudo $0 bbr
  sudo $0 self-update
EOF
    exit 2
    ;;
esac
