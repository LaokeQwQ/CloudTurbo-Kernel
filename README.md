# CloudTurbo Kernel

CloudTurbo Kernel is a VPS-focused custom Linux kernel build repository. It follows upstream Linux kernel sources and automatically builds reproducible kernel packages for x86_64 and arm64.

The repository intentionally stays small: it does not vendor a full kernel tree and does not carry experimental third-party patch stacks. GitHub Actions resolves the selected upstream branch, fetches the source, applies CloudTurbo's VPS-oriented kernel config fragment, and builds artifacts.

## Goals

- Track upstream kernel changes automatically.
- Build for common VPS architectures: x86_64 and arm64.
- Favor reliable cloud operation over desktop tuning.
- Keep the customization auditable through a small config fragment.
- Use `dev` for automation/testing and `main` for the protected stable branch.

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

Artifacts contain the final `.config`, build metadata, logs, and `.deb` files when package building is enabled.

## Upstream Tracking

The **Track Upstream** workflow runs on a schedule and can be started manually. It resolves current upstream heads and updates `state/upstream.json` on the automation branch when an upstream changes. The build workflow can also run on the latest upstream directly without waiting for a state update.

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