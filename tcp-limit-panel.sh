#!/bin/sh
# Alpine/OpenRC TCP 连接数限制面板，适用于代理 VPS。
# 目标是让系统 TCP 总数低于服务商的关机阈值。

set -u

APP_NAME="tcp-cap-panel"
CONF="/etc/tcp-guard.conf"
GUARD="/usr/local/sbin/tcp-guard.sh"
TRIM="/usr/local/sbin/tcp-trim-now.sh"
INIT="/etc/init.d/tcp-guard"
SYSCTL_CONF="/etc/sysctl.d/99-tcp-safe-limit.conf"
LOG="/var/log/tcp-guard.log"
NORMAL_COMMENT="tcp-cap-guard-normal"
EMERGENCY_COMMENT="tcp-cap-guard-emergency"
ALLOW_COMMENT="tcp-cap-guard-allow"

OLD_COMMENTS="tcp-cap-480-normal tcp-cap-480-emergency tcp-cap-guard-normal tcp-cap-guard-emergency tcp-cap-guard-allow"

say() {
  printf '%s\n' "$*"
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    say "请使用 root 用户运行。"
    exit 1
  fi
}

pause() {
  printf '\n按回车继续...'
  # shellcheck disable=SC2034
  read _ans || true
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
  mkdir -p /usr/local/sbin /etc/sysctl.d /etc/iptables
}

install_deps_if_possible() {
  missing=""
  for c in ss iptables iptables-save; do
    if ! have_cmd "$c"; then
      missing="$missing $c"
    fi
  done

  if [ -n "$missing" ]; then
    say "缺少工具：$missing"
    if have_cmd apk; then
      say "正在尝试安装：apk add --no-cache iproute2 iptables"
      apk add --no-cache iproute2 iptables || true
    fi
  fi

  for c in ss iptables iptables-save; do
    if ! have_cmd "$c"; then
      say "安装后仍找不到必需命令：$c"
      exit 1
    fi
  done
}

backup_state() {
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="/root/tcp-limit-backup-$ts"
  mkdir -p "$dir"
  iptables-save > "$dir/iptables-save.before" 2>/dev/null || true
  ip6tables-save > "$dir/ip6tables-save.before" 2>/dev/null || true
  [ -d /etc/iptables ] && cp -a /etc/iptables "$dir/iptables.before" 2>/dev/null || true
  [ -f "$CONF" ] && cp -a "$CONF" "$dir/tcp-guard.conf.before" 2>/dev/null || true
  [ -f "$GUARD" ] && cp -a "$GUARD" "$dir/tcp-guard.sh.before" 2>/dev/null || true
  [ -f "$TRIM" ] && cp -a "$TRIM" "$dir/tcp-trim-now.sh.before" 2>/dev/null || true
  [ -f "$INIT" ] && cp -a "$INIT" "$dir/tcp-guard.init.before" 2>/dev/null || true
  [ -f "$SYSCTL_CONF" ] && cp -a "$SYSCTL_CONF" "$dir/sysctl.before" 2>/dev/null || true
  say "备份目录：$dir"
}

normalize_ports() {
  echo "$1" | tr -d '[:space:]'
}

normalize_number() {
  echo "$1" | tr -d '[:space:]'
}

validate_ports() {
  ports="$1"
  echo "$ports" | grep -Eq '^([0-9]{1,5})(,[0-9]{1,5})*$' || return 1
  oldifs="$IFS"
  IFS=","
  for p in $ports; do
    case "$p" in
      ''|*[!0-9]*) IFS="$oldifs"; return 1 ;;
    esac
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      IFS="$oldifs"
      return 1
    fi
  done
  IFS="$oldifs"
  return 0
}

ports_to_list() {
  echo "$1" | tr ',' ' '
}

ask_value() {
  prompt="$1"
  default="$2"
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read v || v=""
  if [ -z "$v" ]; then
    v="$default"
  fi
  printf '%s' "$v"
}

ask_yes_no() {
  prompt="$1"
  default="$2"
  printf '%s [%s]: ' "$prompt" "$default"
  read v || v=""
  [ -z "$v" ] && v="$default"
  v="$(echo "$v" | tr -d '[:space:]')"
  case "$v" in
    y|Y|yes|YES|Yes|是|对|1) return 0 ;;
    *) return 1 ;;
  esac
}

add_service_name() {
  svc="$1"
  [ -z "$svc" ] && return 0
  case " $service_names " in
    *" $svc "*) ;;
    *) service_names="${service_names:+$service_names }$svc" ;;
  esac
}

choose_services() {
  default="$1"

  say ""
  say "服务状态显示（可多选，仅用于查看状态，脚本不会停止它们）："
  say "  1) xboard-node"
  say "  2) xray"
  say "  3) XrayR"
  say "  4) mihomo"
  say "  5) sing-box"
  say "  6) hysteria-server"
  say "  7) v2ray"
  say "  8) V2bX"
  say "  9) trojan-go"
  say "  0) 不显示服务状态"
  printf '请输入编号或服务名，多个用英文逗号/空格分隔 [%s]: ' "$default" >&2
  read raw || raw=""
  [ -z "$raw" ] && raw="$default"
  raw="$(echo "$raw" | tr ',' ' ')"

  service_names=""
  for item in $raw; do
    case "$item" in
      0|none|None|NONE|无|不显示)
        service_names=""
        break
        ;;
      1) add_service_name xboard-node ;;
      2) add_service_name xray ;;
      3) add_service_name XrayR ;;
      4) add_service_name mihomo ;;
      5) add_service_name sing-box ;;
      6) add_service_name hysteria-server ;;
      7) add_service_name v2ray ;;
      8) add_service_name V2bX ;;
      9) add_service_name trojan-go ;;
      *) add_service_name "$item" ;;
    esac
  done

  printf '%s' "$service_names"
}

clamp_min() {
  v="$1"
  min="$2"
  if [ "$v" -lt "$min" ]; then
    echo "$min"
  else
    echo "$v"
  fi
}

clamp_range() {
  v="$1"
  min="$2"
  max="$3"
  if [ "$v" -lt "$min" ]; then
    echo "$min"
  elif [ "$v" -gt "$max" ]; then
    echo "$max"
  else
    echo "$v"
  fi
}

round_down_10() {
  v="$1"
  echo $((v / 10 * 10))
}

calc_values() {
  cap="$1"

  ingress_limit=$((cap * 25 / 100))
  ingress_limit="$(clamp_min "$ingress_limit" 20)"

  soft=$((cap * 50 / 100))
  hard=$((cap * 75 / 100))
  critical=$((cap * 90 / 100))
  critical="$(round_down_10 "$critical")"
  [ "$critical" -le "$hard" ] && critical=$((hard + 10))
  [ "$critical" -ge "$cap" ] && critical=$((cap - 10))

  tw_cap=$((cap * 25 / 100))
  tw_cap="$(clamp_range "$tw_cap" 32 128)"

  syn_backlog=$((cap * 25 / 100))
  syn_backlog="$(clamp_range "$syn_backlog" 64 256)"

  synack_retries=2
  syn_retries=3
  fin_timeout=15
  keepalive_time=300
  keepalive_intvl=30
  keepalive_probes=3
  nf_syn_timeout=15
  nf_tw_timeout=15
}

remove_managed_rules_for_table() {
  table_cmd="$1"
  have_cmd "$table_cmd" || return 0

  for comment in $OLD_COMMENTS; do
    while :; do
      line="$($table_cmd -L INPUT -n --line-numbers 2>/dev/null | awk -v c="$comment" '$0 ~ c {print $1; exit}')"
      [ -z "$line" ] && break
      $table_cmd -D INPUT "$line" 2>/dev/null || break
    done
  done
}

install_firewall_rules() {
  ports="$1"
  ingress="$2"
  ensure_accept="$3"

  remove_managed_rules_for_table iptables
  remove_managed_rules_for_table ip6tables

  iptables -I INPUT 1 -p tcp -m multiport --dports "$ports" \
    -m conntrack --ctstate NEW \
    -m connlimit --connlimit-above "$ingress" --connlimit-mask 0 \
    -m comment --comment "$NORMAL_COMMENT" \
    -j REJECT --reject-with tcp-reset

  if have_cmd ip6tables; then
    ip6tables -I INPUT 1 -p tcp -m multiport --dports "$ports" \
      -m conntrack --ctstate NEW \
      -m connlimit --connlimit-above "$ingress" --connlimit-mask 0 \
      -m comment --comment "$NORMAL_COMMENT" \
      -j REJECT --reject-with tcp-reset 2>/dev/null || true
  fi

  if [ "$ensure_accept" = "1" ]; then
    iptables -A INPUT -p tcp -m multiport --dports "$ports" -m comment --comment "$ALLOW_COMMENT" -j ACCEPT
    iptables -A INPUT -p udp -m multiport --dports "$ports" -m comment --comment "$ALLOW_COMMENT" -j ACCEPT
    if have_cmd ip6tables; then
      ip6tables -A INPUT -p tcp -m multiport --dports "$ports" -m comment --comment "$ALLOW_COMMENT" -j ACCEPT 2>/dev/null || true
      ip6tables -A INPUT -p udp -m multiport --dports "$ports" -m comment --comment "$ALLOW_COMMENT" -j ACCEPT 2>/dev/null || true
    fi
  fi
}

save_firewall_rules() {
  if [ -x /etc/init.d/iptables ]; then
    /etc/init.d/iptables save >/dev/null 2>&1 || true
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-service iptables start >/dev/null 2>&1 || rc-service iptables restart >/dev/null 2>&1 || true
  elif have_cmd iptables-save; then
    iptables-save > /etc/iptables/rules-save 2>/dev/null || true
  fi

  if have_cmd ip6tables-save; then
    if [ -x /etc/init.d/ip6tables ]; then
      /etc/init.d/ip6tables save >/dev/null 2>&1 || true
      rc-update add ip6tables default >/dev/null 2>&1 || true
      rc-service ip6tables start >/dev/null 2>&1 || true
    else
      ip6tables-save > /etc/iptables/rules6-save 2>/dev/null || true
    fi
  fi
}

sysctl_exists() {
  key="$1"
  sysctl -n "$key" >/dev/null 2>&1
}

sysctl_add_if_exists() {
  key="$1"
  value="$2"
  if sysctl_exists "$key"; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_CONF"
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
  fi
}

write_sysctl_conf() {
  cat > "$SYSCTL_CONF" <<EOF
# 由 $APP_NAME 管理。
# 目标：让这台 VPS 的 TCP 总数低于服务商关机阈值。
EOF
  sysctl_add_if_exists net.ipv4.tcp_syncookies 1
  sysctl_add_if_exists net.ipv4.tcp_synack_retries "$synack_retries"
  sysctl_add_if_exists net.ipv4.tcp_syn_retries "$syn_retries"
  sysctl_add_if_exists net.ipv4.tcp_abort_on_overflow 1
  sysctl_add_if_exists net.ipv4.tcp_max_syn_backlog "$syn_backlog"
  sysctl_add_if_exists net.ipv4.tcp_fin_timeout "$fin_timeout"
  sysctl_add_if_exists net.ipv4.tcp_keepalive_time "$keepalive_time"
  sysctl_add_if_exists net.ipv4.tcp_keepalive_intvl "$keepalive_intvl"
  sysctl_add_if_exists net.ipv4.tcp_keepalive_probes "$keepalive_probes"
  sysctl_add_if_exists net.ipv4.tcp_max_tw_buckets "$tw_cap"
  sysctl_add_if_exists net.netfilter.nf_conntrack_tcp_timeout_syn_sent "$nf_syn_timeout"
  sysctl_add_if_exists net.netfilter.nf_conntrack_tcp_timeout_syn_recv "$nf_syn_timeout"
  sysctl_add_if_exists net.netfilter.nf_conntrack_tcp_timeout_time_wait "$nf_tw_timeout"

  if [ -x /etc/init.d/sysctl ]; then
    rc-update add sysctl boot >/dev/null 2>&1 || true
  fi
}

write_config() {
  cat > "$CONF" <<EOF
PORTS="$ports"
PORT_LIST="$port_list"
CAP="$cap"
INGRESS_LIMIT="$ingress_limit"
SOFT="$soft"
HARD="$hard"
CRITICAL="$critical"
TRIM_ESTABLISHED="$trim_established"
SERVICE_NAMES="$service_names"
SERVICE_NAME="$service_names"
NORMAL_COMMENT="$NORMAL_COMMENT"
EMERGENCY_COMMENT="$EMERGENCY_COMMENT"
LOG="$LOG"
EOF
}

write_guard_script() {
  cat > "$GUARD" <<'EOF'
#!/bin/sh

CONF="/etc/tcp-guard.conf"
[ -r "$CONF" ] && . "$CONF"

PORTS="${PORTS:-25001,25002}"
PORT_LIST="${PORT_LIST:-25001 25002}"
INGRESS_LIMIT="${INGRESS_LIMIT:-120}"
SOFT="${SOFT:-240}"
HARD="${HARD:-360}"
CRITICAL="${CRITICAL:-430}"
TRIM_ESTABLISHED="${TRIM_ESTABLISHED:-1}"
SERVICE_NAMES="${SERVICE_NAMES:-${SERVICE_NAME:-xboard-node}}"
NORMAL_COMMENT="${NORMAL_COMMENT:-tcp-cap-guard-normal}"
EMERGENCY_COMMENT="${EMERGENCY_COMMENT:-tcp-cap-guard-emergency}"
LOG="${LOG:-/var/log/tcp-guard.log}"
EMERGENCY_STATE="/run/tcp-guard.emergency"
TRIM_STATE="/run/tcp-guard.trimmed"

log_msg() {
  printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"
}

ensure_normal_rule() {
  iptables -C INPUT -p tcp -m multiport --dports "$PORTS" \
    -m conntrack --ctstate NEW \
    -m connlimit --connlimit-above "$INGRESS_LIMIT" --connlimit-mask 0 \
    -m comment --comment "$NORMAL_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || \
  iptables -I INPUT 1 -p tcp -m multiport --dports "$PORTS" \
    -m conntrack --ctstate NEW \
    -m connlimit --connlimit-above "$INGRESS_LIMIT" --connlimit-mask 0 \
    -m comment --comment "$NORMAL_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
}

add_emergency_rule() {
  iptables -C INPUT -p tcp -m multiport --dports "$PORTS" \
    -m conntrack --ctstate NEW \
    -m comment --comment "$EMERGENCY_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || \
  iptables -I INPUT 1 -p tcp -m multiport --dports "$PORTS" \
    -m conntrack --ctstate NEW \
    -m comment --comment "$EMERGENCY_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
}

del_emergency_rule() {
  while iptables -D INPUT -p tcp -m multiport --dports "$PORTS" \
    -m conntrack --ctstate NEW \
    -m comment --comment "$EMERGENCY_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done

  while iptables -D INPUT -p tcp -m multiport --dports "$PORTS" \
    -m comment --comment "$EMERGENCY_COMMENT" \
    -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
}

kill_state_for_proxy_port() {
  state="$1"
  for port in $PORT_LIST; do
    ss -K state "$state" "( sport = :$port )" >/dev/null 2>&1 || true
    ss -K state "$state" "( dport = :$port )" >/dev/null 2>&1 || true
  done
}

trim_handshake_sockets() {
  for state in syn-recv syn-sent fin-wait-1 fin-wait-2 closing last-ack close-wait time-wait; do
    kill_state_for_proxy_port "$state"
  done
}

trim_proxy_sockets() {
  trim_handshake_sockets
  if [ "$TRIM_ESTABLISHED" = "1" ]; then
    kill_state_for_proxy_port established
  fi
}

ensure_normal_rule
log_msg "已启动 上限=$CAP 恢复线=$SOFT 硬保护线=$HARD 临界线=$CRITICAL 入站限制=$INGRESS_LIMIT 端口=$PORTS 清理已建立连接=$TRIM_ESTABLISHED 状态服务=$SERVICE_NAMES 动作=不停止服务"

while :; do
  count="$(ss -Htan 2>/dev/null | wc -l | tr -d ' ')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac

  if [ "$count" -ge "$HARD" ]; then
    add_emergency_rule
    trim_handshake_sockets
    if [ ! -e "$EMERGENCY_STATE" ]; then
      log_msg "硬保护触发 total_tcp=$count 动作=拒绝新代理连接并清理握手/残留连接 服务保持运行"
      touch "$EMERGENCY_STATE"
    fi

    if [ "$count" -ge "$CRITICAL" ]; then
      trim_proxy_sockets
      if [ ! -e "$TRIM_STATE" ]; then
        log_msg "临界保护触发 total_tcp=$count 动作=清理代理端口连接 服务保持运行"
        touch "$TRIM_STATE"
      fi
    fi
  elif [ "$count" -le "$SOFT" ]; then
    del_emergency_rule
    if [ -e "$EMERGENCY_STATE" ] || [ -e "$TRIM_STATE" ]; then
      log_msg "已恢复 total_tcp=$count 动作=允许新的代理连接 服务保持运行"
    fi
    rm -f "$EMERGENCY_STATE" "$TRIM_STATE"
  fi

  sleep 2
done
EOF
  chmod 0755 "$GUARD"
}

write_trim_script() {
  cat > "$TRIM" <<'EOF'
#!/bin/sh

CONF="/etc/tcp-guard.conf"
[ -r "$CONF" ] && . "$CONF"
PORT_LIST="${PORT_LIST:-25001 25002}"

with_established=0
if [ "${1:-}" = "--established" ]; then
  with_established=1
fi

show_counts() {
  ss -Htan 2>/dev/null | awk '{s[$1]++} END {for (k in s) print k, s[k]; print "总计", NR}' | sort
}

kill_state_for_proxy_port() {
  state="$1"
  for port in $PORT_LIST; do
    ss -K state "$state" "( sport = :$port )" >/dev/null 2>&1 || true
    ss -K state "$state" "( dport = :$port )" >/dev/null 2>&1 || true
  done
}

echo "清理前："
show_counts

for state in syn-recv syn-sent fin-wait-1 fin-wait-2 closing last-ack close-wait time-wait; do
  kill_state_for_proxy_port "$state"
done

if [ "$with_established" = "1" ]; then
  kill_state_for_proxy_port established
fi

echo "清理后："
show_counts
EOF
  chmod 0755 "$TRIM"
}

write_init_script() {
  cat > "$INIT" <<EOF
#!/sbin/openrc-run

name="tcp-guard"
description="让 TCP 总数低于服务商关机阈值"
command="$GUARD"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="$LOG"
error_log="$LOG"

depend() {
    need net
    after iptables
}
EOF
  chmod 0755 "$INIT"
}

start_guard() {
  if have_cmd rc-update && have_cmd rc-service; then
    rc-update add tcp-guard default >/dev/null 2>&1 || true
    rc-service tcp-guard restart >/dev/null 2>&1 || rc-service tcp-guard start >/dev/null 2>&1 || true
  else
    nohup "$GUARD" >/dev/null 2>&1 &
  fi
}

status_view() {
  say "=== 当前配置 ==="
  if [ -r "$CONF" ]; then
    cat "$CONF"
  else
    say "未安装：缺少 $CONF"
  fi

  say ""
  say "=== TCP 状态 ==="
  if have_cmd ss; then
    ss -Htan 2>/dev/null | awk '{s[$1]++} END {for (k in s) print k, s[k]; print "总计", NR}' | sort
  else
    say "找不到 ss 命令"
  fi

  say ""
  say "=== 服务状态 ==="
  if have_cmd rc-service; then
    rc-service tcp-guard status 2>/dev/null || true
    if [ -r "$CONF" ]; then
      # shellcheck disable=SC1090
      . "$CONF"
      service_status_names="${SERVICE_NAMES:-${SERVICE_NAME:-}}"
      for svc in $service_status_names; do
        printf '%s: ' "$svc"
        rc-service "$svc" status 2>/dev/null || true
      done
    fi
  fi

  say ""
  say "=== 已管理的 iptables 规则 ==="
  iptables -L INPUT -n -v --line-numbers 2>/dev/null | awk '/tcp-cap-guard|Chain INPUT|num/ {print}' || true

  say ""
  say "=== 最近日志 ==="
  tail -20 "$LOG" 2>/dev/null || true
}

install_or_update() {
  ensure_dirs
  install_deps_if_possible

  default_cap="480"
  default_ports="25001,25002"
  default_services="1"

  if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    [ -n "${CAP:-}" ] && default_cap="$CAP"
    [ -n "${PORTS:-}" ] && default_ports="$PORTS"
    [ -n "${SERVICE_NAMES:-}" ] && default_services="$SERVICE_NAMES"
    [ -z "${SERVICE_NAMES:-}" ] && [ -n "${SERVICE_NAME:-}" ] && default_services="$SERVICE_NAME"
  fi

  cap="$(ask_value "服务商 TCP 关机上限" "$default_cap")"
  cap="$(normalize_number "$cap")"
  case "$cap" in
    ''|*[!0-9]*)
      say "上限格式无效。"
      return 1
      ;;
  esac
  if [ "$cap" -lt 100 ]; then
    say "上限太低，至少需要 100。"
    return 1
  fi

  ports="$(ask_value "代理 TCP/UDP 端口，多个端口用英文逗号分隔" "$default_ports")"
  ports="$(normalize_ports "$ports")"
  if ! validate_ports "$ports"; then
    say "端口格式无效：$ports"
    return 1
  fi
  port_list="$(ports_to_list "$ports")"

  service_names="$(choose_services "$default_services")"

  trim_established=1
  if ask_yes_no "达到临界线时是否踢掉已建立的代理 TCP？更安全，但可能让用户短暂断流" "y"; then
    trim_established=1
  else
    trim_established=0
  fi

  ensure_accept=0
  if ask_yes_no "是否为这些端口额外添加放行规则？已有防火墙正常时通常选 n" "n"; then
    ensure_accept=1
  fi

  calc_values "$cap"

  say ""
  say "计算结果："
  say "  服务商上限=$cap"
  say "  新入站 TCP 限制=$ingress_limit"
  say "  恢复线=$soft"
  say "  硬保护线=$hard"
  say "  临界线=$critical"
  say "  TIME_WAIT 上限=$tw_cap"
  say "  SYN 队列=$syn_backlog"
  say "  端口=$ports"
  if [ -n "$service_names" ]; then
    say "  状态显示服务=$service_names（仅查看状态，不会停止）"
  else
    say "  状态显示服务=不显示"
  fi
  say "  是否清理已建立连接=$trim_established"
  say ""
  if ! ask_yes_no "现在应用这些设置？" "y"; then
    say "已取消。"
    return 0
  fi

  backup_state
  install_firewall_rules "$ports" "$ingress_limit" "$ensure_accept"
  save_firewall_rules
  write_sysctl_conf
  write_config
  write_guard_script
  write_trim_script
  write_init_script
  start_guard

  say ""
  say "安装/更新完成。"
  status_view
}

manual_trim_menu() {
  if [ ! -x "$TRIM" ]; then
    say "找不到 $TRIM，请先安装。"
    return 1
  fi
  if ask_yes_no "是否同时踢掉已建立的代理 TCP？" "n"; then
    "$TRIM" --established
  else
    "$TRIM"
  fi
}

uninstall_managed() {
  say "这只会删除脚本管理的 tcp-guard 规则、服务和文件，不会停止你的代理服务。"
  if ! ask_yes_no "继续卸载？" "n"; then
    return 0
  fi

  backup_state
  if have_cmd rc-service; then
    rc-service tcp-guard stop >/dev/null 2>&1 || true
  fi
  if have_cmd rc-update; then
    rc-update del tcp-guard default >/dev/null 2>&1 || true
  fi
  remove_managed_rules_for_table iptables
  remove_managed_rules_for_table ip6tables
  save_firewall_rules
  rm -f "$INIT" "$GUARD" "$TRIM" "$CONF" "$SYSCTL_CONF"
  say "已卸载脚本管理的 tcp-guard 文件和规则。"
}

main_menu() {
  while :; do
    say "==== Alpine/OpenRC TCP 连接数保护面板 ===="
    say "1) 安装或更新保护"
    say "2) 查看状态"
    say "3) 手动清理代理 TCP 状态"
    say "4) 卸载脚本管理的保护"
    say "0) 退出"
    printf '请选择：'
    read choice || choice=""
    case "$choice" in
      1) install_or_update; pause ;;
      2) status_view; pause ;;
      3) manual_trim_menu; pause ;;
      4) uninstall_managed; pause ;;
      0) exit 0 ;;
      *) say "无效选项"; pause ;;
    esac
  done
}

need_root
main_menu
