#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_name="${SOURCE:-xanmod}"
kref="${KERNEL_REF:-auto}"
target_arch="${TARGET_ARCH:-x86_64}"
use_ccache="${USE_CCACHE:-auto}"
build_debs="${BUILD_DEBS:-true}"
localversion="${LOCALVERSION:--cloudturbo}"
jobs="${JOBS:-$(nproc)}"
out_dir="${OUT_DIR:-$repo_root/out/$target_arch}"
work_dir="${WORK_DIR:-$repo_root/build/$target_arch}"

mkdir -p "$out_dir" "$work_dir"
rm -rf "$work_dir/linux-src"

# shellcheck disable=SC2046
eval "$(bash "$repo_root/scripts/resolve-upstream.sh" "$source_name" "$kref")"

branch_ref="${RESOLVED_REF#refs/heads/}"
echo "CloudTurbo build source: $SOURCE_REPO $branch_ref ($RESOLVED_SHA)"

if git ls-remote --exit-code --heads "$SOURCE_REPO" "$branch_ref" >/dev/null 2>&1; then
  git clone --depth=1 --branch "$branch_ref" "$SOURCE_REPO" "$work_dir/linux-src"
else
  git clone --depth=1 "$SOURCE_REPO" "$work_dir/linux-src"
  git -C "$work_dir/linux-src" fetch --depth=1 origin "$RESOLVED_REF"
  git -C "$work_dir/linux-src" checkout --detach FETCH_HEAD
fi

cd "$work_dir/linux-src"

bash "$repo_root/scripts/integrate-tcp-cc.sh" "$work_dir/linux-src"

case "$target_arch" in
  x86_64|amd64)
    karch="x86"
    defconfig="x86_64_defconfig"
    image_target="bzImage"
    image_path="arch/x86/boot/bzImage"
    cross_compile=""
    deb_arch="amd64"
    ;;
  arm64|aarch64)
    karch="arm64"
    defconfig="defconfig"
    image_target="Image"
    image_path="arch/arm64/boot/Image"
    cross_compile="aarch64-linux-gnu-"
    if [[ "$use_ccache" != "false" ]] && command -v ccache >/dev/null 2>&1; then
      export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
      export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
      export CCACHE_BASEDIR="${CCACHE_BASEDIR:-${GITHUB_WORKSPACE:-$repo_root}}"
      export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
      export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
      export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,file_macro,include_file_mtime,include_file_ctime}"
      ccache --set-config=max_size="$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
      cross_compile="ccache aarch64-linux-gnu-"
    fi
    deb_arch="arm64"
    ;;
  *)
    echo "unsupported target arch: $target_arch" >&2
    exit 5
    ;;
esac

make_args=(ARCH="$karch")
if [[ -n "$cross_compile" ]]; then
  make_args+=(CROSS_COMPILE="$cross_compile")
fi

make "${make_args[@]}" "$defconfig"
./scripts/kconfig/merge_config.sh -m .config "$repo_root/config/cloudturbo-vps.config"
make "${make_args[@]}" olddefconfig
make "${make_args[@]}" syncconfig
bash "$repo_root/scripts/check-kernel-config.sh" .config

kernel_version="$(make -s kernelversion)"
kernel_release="$(make -s "${make_args[@]}" kernelrelease LOCALVERSION="$localversion")"
if [[ "$kernel_release" =~ -g[0-9a-f]{7,} ]]; then
  echo "kernel release unexpectedly contains a git suffix: $kernel_release" >&2
  echo "CONFIG_LOCALVERSION_AUTO must stay disabled for deterministic CloudTurbo package names." >&2
  exit 20
fi
{
  echo "source=$SOURCE_NAME"
  echo "source_repo=$SOURCE_REPO"
  echo "requested_ref=$REQUESTED_REF"
  echo "resolved_ref=$RESOLVED_REF"
  echo "resolved_sha=$RESOLVED_SHA"
  echo "kernel_version=$kernel_version"
  echo "kernel_release=$kernel_release"
  echo "target_arch=$target_arch"
  echo "deb_arch=$deb_arch"
  echo "localversion=$localversion"
  echo "build_debs=$build_debs"
  date -u +"built_at=%Y-%m-%dT%H:%M:%SZ"
} | tee "$out_dir/metadata.env"
cp .config "$out_dir/config-$target_arch"

if [[ "$build_debs" == "true" ]]; then
  export KDEB_PKGVERSION="${kernel_version}-1"
  make "${make_args[@]}" -j"$jobs" bindeb-pkg LOCALVERSION="$localversion" 2>&1 | tee "$out_dir/build.log"
  if [[ ! -f vmlinux ]] || ! grep -a -q 'bbrplus' vmlinux; then
    echo "built vmlinux does not contain the bbrplus registration string" >&2
    exit 21
  fi
  if [[ ! -f net/ipv4/tcp_bbrplus.o ]]; then
    echo "net/ipv4/tcp_bbrplus.o was not produced" >&2
    exit 22
  fi
  find "$work_dir" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.ddeb' \) -print -exec cp {} "$out_dir/" \;
else
  make "${make_args[@]}" -j"$jobs" "$image_target" modules LOCALVERSION="$localversion" 2>&1 | tee "$out_dir/build.log"
  if [[ ! -f vmlinux ]] || ! grep -a -q 'bbrplus' vmlinux; then
    echo "built vmlinux does not contain the bbrplus registration string" >&2
    exit 21
  fi
  if [[ ! -f net/ipv4/tcp_bbrplus.o ]]; then
    echo "net/ipv4/tcp_bbrplus.o was not produced" >&2
    exit 22
  fi
  if [[ -f "$image_path" ]]; then
    cp "$image_path" "$out_dir/"
  fi
fi

if command -v ccache >/dev/null 2>&1; then
  ccache -s || true
fi

echo "Artifacts written to $out_dir"
