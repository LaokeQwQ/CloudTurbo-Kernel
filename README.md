# CloudTurbo Kernel

**Language:** English | [简体中文](README.zh-CN.md)

CloudTurbo Kernel is a VPS-focused custom Linux kernel build repository. It follows upstream Linux kernel sources and automatically builds reproducible kernel packages for x86_64 and arm64.

The repository intentionally stays small: it does not vendor a full kernel tree. GitHub Actions resolves the selected upstream branch, fetches the source, injects the CloudTurbo TCP congestion-control additions, applies the VPS-oriented kernel config fragment, and builds artifacts.

## Goals

- Track upstream kernel changes automatically.
- Build for common VPS architectures: x86_64 and arm64.
- Favor reliable cloud operation over desktop tuning.
- Keep the customization auditable through a small config fragment.
- Use `dev` for automation/testing and `main` for the protected stable branch.

## One-Click Install

Run the installer on a Debian/Ubuntu VPS as root:

```bash
bash <(curl -fsSL https://git.laoker.cc/Laoke/CloudTurbo-Kernel/raw/branch/main/install.sh)
```

GitHub raw and GitHub mirror/proxy entry points are also supported:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
bash <(curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
```

At startup the installer shows its script version and release date, clears the screen before each interactive step, and lets you choose English or Simplified Chinese. It also lets you choose the release/update source: the self-hosted `git.laoker.cc`, GitHub, or a GitHub mirror/proxy. You can skip prompts with `CLOUDTURBO_LANG=zh|en` and `CLOUDTURBO_SOURCE=forgejo|github|github-mirror`. The installer supports self-update from the selected source. It will:

- list compiled CloudTurbo Kernel versions from published, non-prerelease releases on the selected source;
- detect the current architecture (`amd64` or `arm64`);
- use the selected source consistently for release metadata, package downloads, and self-update;
- download the selected .deb kernel packages;
- download MD5, SHA1, SHA256, and SHA512 checksum manifests and verify package checksums before installation;
- stop on checksum mismatch by default, with an explicit high-risk confirmation prompt if you choose to continue anyway;
- install the selected version;
- optionally uninstall old kernels while keeping the running and newly installed kernels;
- regenerate GRUB;
- check that the new kernel exists under `/boot`;
- optionally reboot;
- after reboot, choose `bbrplus`, `bbr2` when available, or `bbr` separately, apply it with `fq` pacing, and verify the selected strategy is fully active before reporting success.

The menu also exposes dedicated one-key actions for BBR, BBRPlus, and BBR2. Current XanMod 7.0 builds expose Google's BBRv3 through the kernel algorithm name `bbr`; BBRPlus is built in as `bbrplus`.

Direct commands:

```bash
# Interactive menu
sudo bash install.sh

# Force Simplified Chinese UI
CLOUDTURBO_LANG=zh sudo -E bash install.sh

# Force a source without the interactive prompt
CLOUDTURBO_SOURCE=forgejo sudo -E bash install.sh install
CLOUDTURBO_SOURCE=github sudo -E bash install.sh install
CLOUDTURBO_SOURCE=github-mirror sudo -E bash install.sh install

# Install/upgrade kernel from published releases
sudo bash install.sh install

# After reboot: choose BBRPlus, BBR2 when available, BBR, or another available strategy interactively
sudo bash install.sh tune

# Or enable a specific strategy directly and verify it took effect
sudo bash install.sh bbrplus
sudo bash install.sh bbr2
sudo bash install.sh bbr

# Show current kernel and TCP status
sudo bash install.sh status

# Update the installer script itself
sudo bash install.sh self-update
```

Source behavior:

- `forgejo` uses the self-hosted source at `https://git.laoker.cc/Laoke/CloudTurbo-Kernel`.
- `github` uses GitHub API, GitHub Releases, and raw.githubusercontent.com directly.
- `github-mirror` uses GitHub metadata and assets through a mirror prefix. The default prefix is `https://gh-proxy.org/`, and it can be overridden with `CLOUDTURBO_GITHUB_MIRROR_PREFIX`.

When `github-mirror` is selected, GitHub URLs are rewritten like this:

```text
https://github.com/LaokeQwQ/CloudTurbo-Kernel/releases/download/...
```

becomes:

```text
https://gh-proxy.org/https://github.com/LaokeQwQ/CloudTurbo-Kernel/releases/download/...
```

The same style also works for raw GitHub URLs, for example:

```text
https://gh-proxy.org/https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh
```

## Upstreams

CloudTurbo can build from either source:

- XanMod Linux: `https://gitlab.com/xanmod/linux.git`
- Debian kernel-team Linux: `https://salsa.debian.org/kernel-team/linux.git`

Default workflow source is XanMod with `kernel_ref=auto`. Debian uses `debian/latest` when `kernel_ref=auto`.

## Build

Open **Actions -> Build Kernel -> Run workflow** and choose:

- `source`: `xanmod` or `debian`
- `kernel_ref`: `auto` or an explicit branch/ref
- `arch`: `x86_64`, `arm64`, or `both`
- `build_debs`: whether to produce Debian packages
- `publish_release`: whether to publish `.deb` packages to GitHub Releases for the installer

Artifacts contain the final `.config`, build metadata, logs, checksum manifests, and `.deb` files when package building is enabled. Each published workflow run gets its own release tag, so a rebuild of the same upstream kernel is kept as a separate CloudTurbo build version instead of overwriting the previous release. Published releases are what the one-click installer lists as compiled versions. Release packages include MD5, SHA1, SHA256, and SHA512 manifests, and the installer verifies them before installation. During each build, `scripts/integrate-tcp-cc.sh` injects BBRPlus from the UJX6N 6.x patch source and adapts it to the current TCP congestion-control API. arm64 builds use ccache to speed up repeated cross-compilation when a cache is available.

## Upstream Tracking

The **Track Upstream** workflow runs on a schedule and can be started manually. It resolves current upstream heads and updates `state/upstream.json` on the automation branch when an upstream changes. When an upstream changes, it dispatches package builds for x86_64 and arm64 with `publish_release=true`, so the installer can see the new compiled version after the build completes.

The build workflow can also run on the latest upstream directly without waiting for a state update.

## VPS Defaults

CloudTurbo's config fragment is in `config/cloudturbo-vps.config`. It focuses on:

- KVM, virtio, NVMe, common VPS storage and network drivers.
- TCP BBR/BBRv3, built-in BBRPlus, BBR2 when available, and fq pacing support.
- nftables NAT, bridge netfilter, veth, overlayfs, and iptables fallback support for Docker/container hosts.
- UFW/iptables compatibility modules used by common control panels, including limit, REJECT, and IPv6 rt/hl matches.
- Modern TCP/queue management options.
- Lower debug overhead for production servers.
- Core observability features needed for incident response.

Recommended runtime sysctl values are in `config/sysctl.d/90-cloudturbo.conf`.

## Branch Model

- `main`: protected stable branch.
- `dev`: integration branch for workflow and upstream tracking changes.

Builds are allowed from both branches. Release-quality changes should land through `dev` first and then be merged into `main`.

## License

Repository scripts/configuration are licensed under GPL-2.0-only. Linux kernel source and upstream build outputs remain under their respective upstream licenses.
