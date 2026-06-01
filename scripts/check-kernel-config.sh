#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-.config}"

if [[ ! -f "$config_path" ]]; then
  echo "config file not found: $config_path" >&2
  exit 2
fi

get_config_value() {
  local symbol="$1"
  local line
  line="$(grep -E "^(# )?${symbol}(=| is not set)" "$config_path" | tail -n 1 || true)"
  case "$line" in
    "$symbol=y") echo "y" ;;
    "$symbol=m") echo "m" ;;
    "# $symbol is not set") echo "n" ;;
    "$symbol="*) echo "${line#*=}" ;;
    *) echo "missing" ;;
  esac
}

require_value() {
  local symbol="$1"
  local expected="$2"
  local actual
  actual="$(get_config_value "$symbol")"
  if [[ "$actual" != "$expected" ]]; then
    echo "required $symbol=$expected, got $actual" >&2
    return 1
  fi
}

require_enabled() {
  local symbol="$1"
  local actual
  actual="$(get_config_value "$symbol")"
  if [[ "$actual" != "y" && "$actual" != "m" ]]; then
    echo "required $symbol enabled, got $actual" >&2
    return 1
  fi
}

required_builtin=(
  CONFIG_TCP_CONG_BBR
  CONFIG_TCP_CONG_BBRPLUS
  CONFIG_NET_SCH_FQ
  CONFIG_NF_CONNTRACK
  CONFIG_NF_NAT
  CONFIG_NF_TABLES
  CONFIG_NF_TABLES_INET
  CONFIG_NF_TABLES_IPV4
  CONFIG_NF_TABLES_IPV6
  CONFIG_NFT_CT
  CONFIG_NFT_NAT
  CONFIG_NFT_MASQ
  CONFIG_NFT_REDIR
  CONFIG_BRIDGE
  CONFIG_BRIDGE_NETFILTER
  CONFIG_VETH
  CONFIG_OVERLAY_FS
  CONFIG_NET_NS
  CONFIG_CGROUPS
  CONFIG_CGROUP_BPF
  CONFIG_MEMCG
  CONFIG_SECCOMP
  CONFIG_SECCOMP_FILTER
)

required_enabled=(
  CONFIG_NF_CONNTRACK_BRIDGE
  CONFIG_NFT_COMPAT
  CONFIG_IP_NF_IPTABLES
  CONFIG_IP_NF_IPTABLES_LEGACY
  CONFIG_IP_NF_NAT
  CONFIG_IP_NF_TARGET_MASQUERADE
  CONFIG_IP6_NF_IPTABLES
  CONFIG_IP6_NF_NAT
  CONFIG_NETFILTER_XTABLES
  CONFIG_NETFILTER_XTABLES_LEGACY
  CONFIG_NETFILTER_XT_NAT
  CONFIG_NETFILTER_XT_TARGET_MASQUERADE
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
  CONFIG_NETFILTER_XT_MATCH_CONNTRACK
)

failed=0

for symbol in "${required_builtin[@]}"; do
  require_value "$symbol" "y" || failed=1
done

for symbol in "${required_enabled[@]}"; do
  require_enabled "$symbol" || failed=1
done

if [[ "$(get_config_value CONFIG_DEFAULT_TCP_CONG)" != '"bbr"' ]]; then
  echo "required CONFIG_DEFAULT_TCP_CONG=\"bbr\", got $(get_config_value CONFIG_DEFAULT_TCP_CONG)" >&2
  failed=1
fi

if [[ "$(get_config_value CONFIG_LOCALVERSION_AUTO)" != "n" ]]; then
  echo "required CONFIG_LOCALVERSION_AUTO disabled, got $(get_config_value CONFIG_LOCALVERSION_AUTO)" >&2
  failed=1
fi

if (( failed )); then
  echo "CloudTurbo kernel config audit failed." >&2
  exit 1
fi

echo "CloudTurbo kernel config audit passed."
