# CloudTurbo Kernel

**Language:** English | [简体中文](README.zh-CN.md)

CloudTurbo Kernel is a VPS-focused custom Linux kernel build repository. It follows upstream Linux kernel sources and automatically builds reproducible kernel packages for x86_64 and arm64.

The repository intentionally stays small: it does not vendor a full kernel tree and does not carry experimental third-party patch stacks. GitHub Actions resolves the selected upstream branch, fetches the source, applies CloudTurbo's VPS-oriented kernel config fragment, and builds artifacts.

## Goals

- Track upstream kernel changes automatically.
- Build for common VPS architectures: x86_64 and arm64.
- Favor reliable cloud operation over desktop tuning.
- Keep the customization auditable through a small config fragment.
- Use `dev` for automation/testing and `main` for the protected stable branch.

## One-Click Install

Run the installer on a Debian/Ubuntu VPS as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
```

If GitHub access is slow, you can fetch the installer itself through a mirror/proxy:

```bash
bash <(curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
```

At startup the installer shows its script version and release date, clears the screen before each interactive step, and lets you choose English or Simplified Chinese. You can also skip the prompt with `CLOUDTURBO_LANG=zh` or `CLOUDTURBO_LANG=en`. The installer supports self-update from the main branch. It will:

- list compiled CloudTurbo Kernel versions from GitHub Releases;
- detect the current architecture (`amd64` or `arm64`);
- ask whether to use a mirror before downloading packages;
- download the selected `.deb` kernel packages;
- install the selected version;
- optionally uninstall old kernels while keeping the running and newly installed kernels;
- regenerate GRUB;
- check that the new kernel exists under `/boot`;
- optionally reboot;
- after reboot, enable available TCP acceleration features such as `bbrplus` or `bbr` with `fq` pacing.

Direct commands:

```bash
# Interactive menu
sudo bash install.sh

# Force Simplified Chinese UI
CLOUDTURBO_LANG=zh sudo -E bash install.sh

# Install/upgrade kernel from published releases
sudo bash install.sh install

# After reboot: enable BBRPlus/BBR if the running kernel provides it
sudo bash install.sh tune

# Show current kernel and TCP status
sudo bash install.sh status

# Update the installer script itself
sudo bash install.sh self-update
```

Mirror behavior: before package download, the installer asks whether to use a mirror prefix. If you answer yes and keep the default, release asset URLs are rewritten like this:

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

Artifacts contain the final `.config`, build metadata, logs, and `.deb` files when package building is enabled. Published releases are what the one-click installer lists as compiled versions.

## Upstream Tracking

The **Track Upstream** workflow runs on a schedule and can be started manually. It resolves current upstream heads and updates `state/upstream.json` on the automation branch when an upstream changes. When an upstream changes, it dispatches package builds for x86_64 and arm64 with `publish_release=true`, so the installer can see the new compiled version after the build completes.

The build workflow can also run on the latest upstream directly without waiting for a state update.

## VPS Defaults

CloudTurbo's config fragment is in `config/cloudturbo-vps.config`. It focuses on:

- KVM, virtio, NVMe, common VPS storage and network drivers.
- TCP BBR and fq pacing support.
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