# CloudTurbo Kernel

**语言：** [English](README.md) | 简体中文

CloudTurbo Kernel 是一个专为 VPS 稳定运行优化的定制 Linux 内核构建仓库。它跟随上游 Linux 内核源码更新，并自动为 x86_64 与 arm64 架构构建可复现的内核包。

仓库本身保持轻量：不内置完整内核源码。GitHub Actions 会解析选定的上游分支、拉取源码、注入 CloudTurbo 的 TCP 拥塞控制扩展、合并 VPS 配置片段，然后生成构建产物。

## 目标

- 自动跟踪上游内核更新。
- 支持常见 VPS 架构：x86_64 与 arm64。
- 优先保证云服务器长期稳定运行，而不是桌面体验调优。
- 通过小而清晰的配置片段保持定制内容可审计。
- 使用 `dev` 作为自动化/集成分支，`main` 作为受保护的稳定分支。

## 一键安装

在 Debian/Ubuntu VPS 上以 root 身份运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
```

如果 GitHub 访问较慢，可以通过镜像/代理拉取安装脚本：

```bash
bash <(curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh)
```

安装脚本启动时会显示脚本版本号和发布日期，每次进入交互步骤前会自动清屏，并让你选择 English 或简体中文。也可以通过 `CLOUDTURBO_LANG=zh` 或 `CLOUDTURBO_LANG=en` 跳过选择。安装脚本支持从 main 分支自更新。安装脚本会：

- 从 GitHub Releases 自动列出已编译的 CloudTurbo Kernel 版本；
- 自动识别当前架构（`amd64` 或 `arm64`）；
- 下载内核包前询问是否使用镜像站；
- 下载选中的 .deb 内核包；
- 下载 MD5、SHA1、SHA256、SHA512 校验清单，并在安装前逐包计算和比对；
- 安装选中的内核版本；
- 可选卸载旧内核，并保留当前运行内核与新安装内核；
- 自动重新生成 GRUB 配置；
- 检查新内核是否存在于 `/boot`；
- 可选立即重启；
- 重启后可分别选择 `bbrplus`、可用时的 `bbr2` 或 `bbr`，配合 `fq` pacing 应用，并在确认所选策略完全生效后才提示成功。

主菜单也提供 BBR、BBRPlus、BBR2 三个独立的一键启用入口。当前 XanMod 7.0 构建中，Google BBRv3 以 Linux 内核算法名 `bbr` 暴露；BBRPlus 会以内置算法 `bbrplus` 暴露。

常用命令：

```bash
# 交互式菜单
sudo bash install.sh

# 强制使用中文界面
CLOUDTURBO_LANG=zh sudo -E bash install.sh

# 从已发布版本安装/升级内核
sudo bash install.sh install

# 重启进入新内核后：交互选择 BBRPlus、可用时的 BBR2、BBR 或其他可用策略
sudo bash install.sh tune

# 或直接启用指定策略，并验证是否完全生效
sudo bash install.sh bbrplus
sudo bash install.sh bbr2
sudo bash install.sh bbr

# 查看当前内核与 TCP 状态
sudo bash install.sh status

# 更新安装脚本自身
sudo bash install.sh self-update
```

镜像站逻辑：下载安装包前，脚本会询问是否使用镜像前缀。如果选择是并保留默认值，Release 资源 URL 会按如下方式重写：

```text
https://github.com/LaokeQwQ/CloudTurbo-Kernel/releases/download/...
```

变为：

```text
https://gh-proxy.org/https://github.com/LaokeQwQ/CloudTurbo-Kernel/releases/download/...
```

同样也适用于 raw GitHub 地址，例如：

```text
https://gh-proxy.org/https://raw.githubusercontent.com/LaokeQwQ/CloudTurbo-Kernel/main/install.sh
```

## 上游来源

CloudTurbo 可以从以下上游构建：

- XanMod Linux：`https://gitlab.com/xanmod/linux.git`
- Debian kernel-team Linux：`https://salsa.debian.org/kernel-team/linux.git`

默认 workflow 使用 XanMod，并设置 `kernel_ref=auto`。Debian 源在 `kernel_ref=auto` 时使用 `debian/latest`。

## 构建

打开 **Actions -> Build Kernel -> Run workflow**，选择：

- `source`：`xanmod` 或 `debian`
- `kernel_ref`：`auto` 或显式分支/引用
- `arch`：`x86_64`、`arm64` 或 `both`
- `build_debs`：是否生成 Debian 包
- `publish_release`：是否将 `.deb` 发布到 GitHub Releases，供一键安装脚本列出和下载

构建产物包含最终 `.config`、构建元数据、日志、校验清单，以及在启用包构建时生成的 `.deb` 文件。安装脚本列出的“已编译版本”来自 GitHub Releases。发布版本会附带 MD5、SHA1、SHA256、SHA512 校验清单，安装脚本会在安装前完成比对。每次构建时，`scripts/integrate-tcp-cc.sh` 会从 UJX6N 的 6.x patch 源注入 BBRPlus，并适配当前 TCP 拥塞控制 API。arm64 构建会在可用时使用 ccache 加快重复交叉编译。

## 上游跟踪

**Track Upstream** workflow 会定时运行，也可以手动触发。它会解析当前上游 HEAD，并在上游发生变化时更新 `state/upstream.json`。如果检测到上游更新，它会为 x86_64 和 arm64 触发构建，并使用 `publish_release=true` 发布新版本，安装脚本会在构建完成后看到新版本。

也可以不等待上游跟踪，直接手动运行构建 workflow。

## VPS 默认配置

CloudTurbo 的配置片段位于 `config/cloudturbo-vps.config`，重点包括：

- KVM、virtio、NVMe，以及常见 VPS 存储和网络驱动；
- TCP BBR/BBRv3、内置 BBRPlus、可用时的 BBR2，以及 `fq` pacing 支持；
- 为 Docker/容器主机启用 nftables NAT、bridge netfilter、veth、overlayfs 与 iptables 兼容回退；
- 现代 TCP/队列管理选项；
- 面向生产服务器的低调试开销；
- 事故排查所需的基础可观测能力。

推荐运行时 sysctl 配置位于 `config/sysctl.d/90-cloudturbo.conf`。

## 分支模型

- `main`：受保护的稳定分支。
- `dev`：workflow 与上游跟踪的集成分支。

两个分支都可以用于构建。正式变更建议先进入 `dev`，确认后再合入 `main`。

## 许可证

仓库内脚本和配置使用 GPL-2.0-only。Linux 内核源码和上游构建产物仍遵循各自上游许可证。
