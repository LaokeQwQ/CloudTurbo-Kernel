#!/usr/bin/env bash
set -euo pipefail

kernel_dir="${1:-.}"
bbrplus_patch_url="${BBRPLUS_PATCH_URL:-https://raw.githubusercontent.com/UJX6N/bbrplus-6.x_stable/main/convert_official_linux-6.9.x_src_to_bbrplus.patch}"
bbrplus_patch_fallback_url="${BBRPLUS_PATCH_FALLBACK_URL:-https://gh-proxy.org/https://raw.githubusercontent.com/UJX6N/bbrplus-6.x_stable/main/convert_official_linux-6.9.x_src_to_bbrplus.patch}"

cd "$kernel_dir"

for required in net/ipv4/Kconfig net/ipv4/Makefile include/net/tcp.h net/ipv4/tcp_bbr.c; do
  if [[ ! -f "$required" ]]; then
    echo "missing kernel source file: $required" >&2
    exit 11
  fi
done

echo "CloudTurbo TCP CC integration: BBRPlus from UJX6N patch source"
if grep -Eq '#define[[:space:]]+BBR_VERSION[[:space:]]+3' net/ipv4/tcp_bbr.c; then
  echo "CloudTurbo TCP CC integration: upstream tcp_bbr.c reports BBR_VERSION 3; algorithm name remains bbr"
fi

perl -0pi -e 's/\r\n/\n/g' net/ipv4/Kconfig net/ipv4/Makefile

if ! grep -q 'config TCP_CONG_BBRPLUS' net/ipv4/Kconfig; then
  perl -0pi -e 's/\nchoice\n\tprompt "Default TCP congestion control"/\nconfig TCP_CONG_BBRPLUS\n\ttristate "BBRPlus TCP"\n\tdefault n\n\thelp\n\t  BBRPlus is an enhanced BBR-derived TCP congestion control\n\t  originally introduced by dog250 and cx9208. Like BBR, it benefits\n\t  from fq pacing.\n\nchoice\n\tprompt "Default TCP congestion control"/' net/ipv4/Kconfig
fi

if ! grep -q 'config DEFAULT_BBRPLUS' net/ipv4/Kconfig; then
  perl -0pi -e 's/(\n\tconfig DEFAULT_BBR\n\t\tbool "BBR" if TCP_CONG_BBR=y\n)/$1\n\tconfig DEFAULT_BBRPLUS\n\t\tbool "BBRPlus" if TCP_CONG_BBRPLUS=y\n/' net/ipv4/Kconfig
fi

if ! grep -q 'default "bbrplus" if DEFAULT_BBRPLUS' net/ipv4/Kconfig; then
  perl -0pi -e 's/(\n\tdefault "bbr" if DEFAULT_BBR\n)/$1\tdefault "bbrplus" if DEFAULT_BBRPLUS\n/' net/ipv4/Kconfig
fi

if ! grep -q 'CONFIG_TCP_CONG_BBRPLUS' net/ipv4/Makefile; then
  perl -0pi -e 's/(obj-\$\(CONFIG_TCP_CONG_BBR\)[[:space:]]+\+= tcp_bbr\.o\n)/$1obj-\$\(CONFIG_TCP_CONG_BBRPLUS\) += tcp_bbrplus.o\n/' net/ipv4/Makefile
fi

if ! grep -q 'config TCP_CONG_BBRPLUS' net/ipv4/Kconfig ||
   ! grep -q 'config DEFAULT_BBRPLUS' net/ipv4/Kconfig ||
   ! grep -q 'default "bbrplus" if DEFAULT_BBRPLUS' net/ipv4/Kconfig ||
   ! grep -q 'CONFIG_TCP_CONG_BBRPLUS' net/ipv4/Makefile; then
  echo "failed to inject BBRPlus Kconfig/Makefile entries" >&2
  exit 14
fi

if [[ -f net/ipv4/tcp_bbrplus.c ]]; then
  echo "CloudTurbo TCP CC integration: net/ipv4/tcp_bbrplus.c already exists"
  exit 0
fi

tmp_patch="$(mktemp)"
tmp_c="$(mktemp)"
trap 'rm -f "$tmp_patch" "$tmp_c"' EXIT

download_patch() {
  local url
  for url in "$bbrplus_patch_url" "$bbrplus_patch_fallback_url"; do
    [[ -n "$url" ]] || continue
    echo "CloudTurbo TCP CC integration: downloading BBRPlus patch from $url"
    if curl -fL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 180 "$url" -o "$tmp_patch"; then
      return 0
    fi
  done
  echo "failed to download BBRPlus patch from configured URLs" >&2
  return 1
}

download_patch

awk '
  /^diff .* b\/net\/ipv4\/tcp_bbrplus\.c$/ { in_file = 1; next }
  in_file && /^diff / { exit }
  in_file && /^--- / { next }
  in_file && /^\+\+\+ / { next }
  in_file && /^@@/ { next }
  in_file {
    if (substr($0, 1, 1) == "+") {
      print substr($0, 2)
    }
  }
' "$tmp_patch" > "$tmp_c"

if [[ ! -s "$tmp_c" ]]; then
  echo "failed to extract tcp_bbrplus.c from $bbrplus_patch_url" >&2
  exit 12
fi

# Adapt the UJX6N 6.9 BBRPlus source for the TCP congestion-control API
# used by current XanMod/mainline kernels.
perl -0pi -e 's/\n#include <linux\/btf\.h>\n/\n/; s/\n#include <linux\/btf_ids\.h>\n/\n/' "$tmp_c"
perl -0pi -e 's/__bpf_kfunc\s+//g' "$tmp_c"
perl -0pi -e 's/^u32 bbr_max_bw/static u32 bbr_max_bw/mg; s/^u32 bbr_inflight/static u32 bbr_inflight/mg' "$tmp_c"
perl -0pi -e 's/tcp_tso_autosize/bbrplus_tso_autosize/g' "$tmp_c"

perl -0pi -e 's@(/\* Return count of segments we want in the skbs we send, or 0 for default\. \*/\nstatic u32 bbr_tso_segs_goal)@static u32 bbrplus_tso_autosize(const struct sock *sk, unsigned int mss_now,\n\t\t\t\t       int min_tso_segs)\n{\n\tunsigned long bytes;\n\tu32 r;\n\n\tbytes = READ_ONCE(sk->sk_pacing_rate) >> READ_ONCE(sk->sk_pacing_shift);\n\tr = tcp_min_rtt(tcp_sk(sk)) >> READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_tso_rtt_log);\n\tif (r < BITS_PER_TYPE(sk->sk_gso_max_size))\n\t\tbytes += sk->sk_gso_max_size >> r;\n\n\tbytes = min_t(unsigned long, bytes, sk->sk_gso_max_size);\n\n\treturn max_t(u32, bytes / mss_now, min_tso_segs);\n}\n\n$1@' "$tmp_c"

perl -0pi -e 's@static u32 bbr_tso_segs_goal\(struct sock \*sk\)\n\{\n    struct bbr \*bbr = inet_csk_ca\(sk\);\n\n    return bbr->tso_segs_goal;\n\}\n@static u32 bbr_tso_segs_goal(struct sock *sk)\n{\n    struct bbr *bbr = inet_csk_ca(sk);\n\n    return bbr->tso_segs_goal;\n}\n\nstatic u32 bbr_tso_segs(struct sock *sk, unsigned int mss_now)\n{\n    u32 min_segs;\n\n    min_segs = READ_ONCE(sk->sk_pacing_rate) < (bbr_min_tso_rate >> 3) ? 1 : 2;\n    return min(bbrplus_tso_autosize(sk, mss_now, min_segs), 0x7FU);\n}\n@' "$tmp_c"

perl -0pi -e 's/static void bbr_main\(struct sock \*sk, const struct rate_sample \*rs\)/static void bbr_main(struct sock *sk, u32 ack, int flag,\n\t\t\t     const struct rate_sample *rs)/' "$tmp_c"
perl -0pi -e 's/(static void bbr_main\(struct sock \*sk, u32 ack, int flag,\n\t\t\t     const struct rate_sample \*rs\)\n\{\n    struct bbr \*bbr = inet_csk_ca\(sk\);\n    u32 bw;\n\n)/$1    (void)ack;\n    (void)flag;\n\n/' "$tmp_c"
perl -0pi -e 's/\.tso_segs_goal\s+= bbr_tso_segs_goal,/.tso_segs   = bbr_tso_segs,/' "$tmp_c"
perl -0pi -e 's/BTF_SET8_START\(tcp_bbr_check_kfunc_ids\).*?static int __init bbr_register/static int __init bbr_register/s' "$tmp_c"
perl -0pi -e 's/static int __init bbr_register\(void\)\n\{\n    int ret;\n\n    BUILD_BUG_ON\(sizeof\(struct bbr\) > ICSK_CA_PRIV_SIZE\);\n\n\tret = register_btf_kfunc_id_set\(BPF_PROG_TYPE_STRUCT_OPS, &tcp_bbr_kfunc_set\);\n\tif \(ret < 0\)\n        return ret;\n\treturn tcp_register_congestion_control\(&tcp_bbr_cong_ops\);\n\}/static int __init bbr_register(void)\n{\n    BUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);\n\n    return tcp_register_congestion_control(\&tcp_bbr_cong_ops);\n}/' "$tmp_c"
perl -0pi -e 's/MODULE_DESCRIPTION\("TCP BBR \(Bottleneck Bandwidth and RTT\)"\);/MODULE_DESCRIPTION("TCP BBRPlus (Bottleneck Bandwidth and RTT)");/' "$tmp_c"

if grep -Eq '\.tso_segs_goal|register_btf_kfunc_id_set|BTF_SET8|BTF_KFUNCS|__bpf_kfunc' "$tmp_c"; then
  echo "tcp_bbrplus.c still contains unsupported API markers" >&2
  grep -En '\.tso_segs_goal|register_btf_kfunc_id_set|BTF_SET8|BTF_KFUNCS|__bpf_kfunc' "$tmp_c" >&2 || true
  exit 13
fi

install -m 0644 "$tmp_c" net/ipv4/tcp_bbrplus.c
echo "CloudTurbo TCP CC integration: added net/ipv4/tcp_bbrplus.c"
