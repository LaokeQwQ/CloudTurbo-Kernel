#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="LaokeQwQ"
REPO="CloudTurbo-Kernel"
API_BASE="https://api.github.com/repos/${OWNER}/${REPO}"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh"
WORK_DIR="${WORK_DIR:-/tmp/cloudturbo-kernel-installer}"
SYSCTL_FILE="/etc/sysctl.d/99-cloudturbo-tcp.conf"
DEFAULT_MIRROR_PREFIX="https://gh-proxy.org/"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "This command must be run as root. Try: sudo bash install.sh"
    exit 1
  fi
}

is_debian_like() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  [[ "${ID:-}" =~ ^(debian|ubuntu)$ || " ${ID_LIKE:-} " == *" debian "* ]]
}

install_dependencies() {
  need_root
  if ! is_debian_like; then
    red "CloudTurbo installer currently supports Debian/Ubuntu-like systems only."
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl python3 dpkg-dev apt-transport-https gnupg lsb-release
}

arch_deb() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) red "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer
  local suffix="[y/N]"
  [[ "$default" == "Y" ]] && suffix="[Y/n]"
  read -r -p "$prompt $suffix " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

configure_mirror() {
  MIRROR_PREFIX=""
  if ask_yes_no "Use a GitHub mirror/proxy before downloading assets?" "N"; then
    read -r -p "Mirror prefix [${DEFAULT_MIRROR_PREFIX}] " MIRROR_PREFIX || true
    MIRROR_PREFIX="${MIRROR_PREFIX:-$DEFAULT_MIRROR_PREFIX}"
    MIRROR_PREFIX="${MIRROR_PREFIX%/}/"
    yellow "Download mirror enabled: ${MIRROR_PREFIX}<original-url>"
    yellow "Example: ${MIRROR_PREFIX}${RAW_INSTALL_URL}"
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
if not releases:
    sys.exit(3)
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
  local release_table
  set +e
  release_table="$(list_releases "$deb_arch")"
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$release_table" ]]; then
    red "No compiled CloudTurbo Kernel release assets were found for ${deb_arch}."
    yellow "Build one first from GitHub Actions: Build Kernel -> build_debs=true -> publish_release=true."
    exit 1
  fi

  blue "Available CloudTurbo Kernel releases for ${deb_arch}:"
  printf '%s\n' "$release_table" | awk -F '\t' '{printf "  %2s) %-34s %s assets  %s\n", $1, $2, $5, $4}'
  local choice
  while true; do
    read -r -p "Select a release number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && printf '%s\n' "$release_table" | awk -F '\t' '{print $1}' | grep -qx "$choice"; then
      printf '%s\n' "$release_table" | awk -F '\t' -v n="$choice" '$1 == n {print $2; exit}'
      return 0
    fi
    yellow "Invalid selection."
  done
}

download_release_assets() {
  local tag="$1"
  local deb_arch="$2"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  configure_mirror
  blue "Fetching release metadata: ${tag}"
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
    print(f"{name}\t{asset.get(\"browser_download_url\", \"\")}")
' "$deb_arch" > "${WORK_DIR}/assets.tsv"
  if [[ ! -s "${WORK_DIR}/assets.tsv" ]]; then
    red "Release ${tag} has no .deb assets for ${deb_arch}."
    exit 1
  fi
  blue "Downloading packages into ${WORK_DIR}:"
  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue
    local final_url
    final_url="$(mirror_url "$url")"
    printf '  - %s\n' "$name"
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
  blue "Installing downloaded kernel packages..."
  dpkg -i "$WORK_DIR"/*.deb || apt-get -f install -y
  local versions
  versions="$(installed_kernel_versions_from_debs)"
  if [[ -z "$versions" ]]; then
    yellow "Could not infer installed kernel version from downloaded linux-image packages."
  else
    green "Installed kernel version(s):"
    printf '%s\n' "$versions" | sed 's/^/  - /'
  fi
}

purge_old_kernels() {
  need_root
  local keep_versions="$1"
  local current
  current="$(uname -r)"
  blue "Current running kernel: ${current}"
  blue "New kernel version(s) to keep:"
  printf '%s\n' "$keep_versions" | sed 's/^/  - /'
  if ! ask_yes_no "Purge old kernel packages now? Current and newly installed kernels will be kept." "Y"; then
    yellow "Skipping old kernel purge."
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
    green "No old kernel packages to purge."
    return 0
  fi
  yellow "Packages to purge:"
  printf '  - %s\n' "${purge[@]}"
  apt-get purge -y "${purge[@]}"
  apt-get autoremove --purge -y
}

update_bootloader() {
  need_root
  blue "Regenerating GRUB configuration..."
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
    red "No GRUB update command found. Please update bootloader manually."
    exit 1
  fi
}

check_installed_kernel() {
  local versions="$1"
  local missing=0
  while IFS= read -r ver; do
    [[ -z "$ver" ]] && continue
    if [[ -f "/boot/vmlinuz-${ver}" ]]; then
      green "Found /boot/vmlinuz-${ver}"
    else
      red "Missing /boot/vmlinuz-${ver}"
      missing=1
    fi
  done <<< "$versions"
  return "$missing"
}

reboot_prompt() {
  if ask_yes_no "Reboot now to start CloudTurbo Kernel?" "Y"; then
    blue "Rebooting..."
    reboot
  else
    yellow "Reboot skipped. Boot into the new kernel before enabling TCP features."
  fi
}

install_kernel_flow() {
  need_root
  install_dependencies
  local deb_arch tag versions
  deb_arch="$(arch_deb)"
  tag="$(select_release "$deb_arch")"
  yellow "Selected release: ${tag}"
  download_release_assets "$tag" "$deb_arch"
  install_downloaded_debs
  versions="$(installed_kernel_versions_from_debs)"
  purge_old_kernels "$versions"
  update_bootloader
  check_installed_kernel "$versions"
  reboot_prompt
}

available_cc() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

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
  blue "Available congestion controls: ${cc_list:-unknown}"
  for cc in bbrplus bbr brutal cubic; do
    if printf '%s\n' "$cc_list" | tr ' ' '\n' | grep -qx "$cc"; then
      choices+=("$cc")
    fi
  done
  if [[ ${#choices[@]} -eq 0 ]]; then
    red "No supported congestion control found. Is the new kernel running?"
    exit 1
  fi
  blue "Select TCP congestion control:"
  local i=1
  for cc in "${choices[@]}"; do
    if [[ "$cc" == "brutal" ]]; then
      printf '  %d) %s (advanced; only use if your software supports TCP Brutal params)\n' "$i" "$cc"
    else
      printf '  %d) %s\n' "$i" "$cc"
    fi
    i=$((i+1))
  done
  while true; do
    read -r -p "Choice [1]: " num
    num="${num:-1}"
    if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#choices[@]} ]]; then
      selected="${choices[$((num-1))]}"
      break
    fi
    yellow "Invalid selection."
  done

  if [[ "$selected" == "brutal" ]]; then
    yellow "TCP Brutal is usually application-selected, not a safe global default."
    if ! ask_yes_no "Set brutal as global default anyway?" "N"; then
      yellow "Skipped setting brutal as global default."
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
  green "Enabled ${selected} with fq pacing."
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
}

show_status() {
  blue "CloudTurbo Kernel status"
  printf '  Running kernel: %s\n' "$(uname -r)"
  printf '  Architecture:   %s (%s)\n' "$(uname -m)" "$(arch_deb)"
  printf '  Available CC:   %s\n' "$(available_cc)"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
  printf '\nInstalled kernel images:\n'
  dpkg-query -W -f='  ${Package}\t${Version}\n' 'linux-image-*' 2>/dev/null | grep -E '^  linux-image-[0-9]' || true
}

menu() {
  while true; do
    cat <<'EOF'

CloudTurbo Kernel installer
  1) Install/upgrade CloudTurbo Kernel from GitHub Releases
  2) Enable TCP acceleration after reboot (BBRPlus/BBR when available)
  3) Regenerate GRUB
  4) Show kernel/TCP status
  0) Exit
EOF
    read -r -p "Choose an option: " opt
    case "$opt" in
      1) install_kernel_flow ;;
      2) enable_tcp_features ;;
      3) update_bootloader ;;
      4) show_status ;;
      0) exit 0 ;;
      *) yellow "Invalid option." ;;
    esac
  done
}

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
  bash $0 tune
EOF
    exit 2
    ;;
esac