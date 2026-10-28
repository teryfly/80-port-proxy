#!/usr/bin/env bash
# 启停控制。start / reload 都会先把 routes.conf 应用到 nginx, 再确保服务在跑, 可反复执行。
#
# 用法: ./start.sh [start|reload|restart|stop|status]      (默认 start)
#   start    拉起服务并应用最新 routes.conf
#   reload   改完 routes.conf 后热生效, 不断连接(等价于 ./deploy.sh)
#   restart  先校验并写入配置, 再完全重启 nginx, 会短暂中断
#   stop     停掉 nginx。注意: 停的是整个 nginx, 本机其它站点一起下线, 80/443 端口随之释放
#   status   看服务状态、两个端口的生效版本、证书、规则数、最近日志
set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -gt 1 ]]; then
  echo "只接受一个子命令, 见 --help" >&2
  exit 2
fi
cmd="${1:-start}"
case "$cmd" in
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

sudo -n true || { echo "需要 root 或免密 sudo" >&2; exit 1; }
command -v nginx >/dev/null || { echo "nginx 未安装, 请先执行 ./install.sh" >&2; exit 1; }

AVAIL=/etc/nginx/sites-available/hostproxy.conf
ENABLED=/etc/nginx/sites-enabled/hostproxy.conf
[[ -f routes.conf ]] || { echo "当前目录没有 routes.conf" >&2; exit 1; }

# 端口/证书目录从已装的配置里读, 而不是看环境变量, 这样 status 反映的是真实生效的那份。
# 靠 render.py 写在文件头的三行标记, 不再 grep listen —— 现在 80 和 443 都在里面。
marker() { sed -n "s/^# hostproxy-$1: //p" "$AVAIL" 2>/dev/null | head -1; }
PORT=$(marker port); PORT=${PORT:-80}
HTTPSPORT=$(marker https-port)
[[ $HTTPSPORT =~ ^[0-9]+$ ]] || HTTPSPORT=""      # 空 = 这份配置是 HTTPS=off 渲染的
CERTS=$(marker certs-dir)
[[ -n $CERTS ]] || CERTS=$(python3 render.py --print-defaults | sed -n 's/^CERTS_DIR_DEFAULT=//p')
RT=(--port "$PORT" --certs-dir "$CERTS")
if [[ -n $HTTPSPORT ]]; then RT+=(--https-port "$HTTPSPORT"); else RT+=(--no-https); fi

FALLBACK_HOST=probe-missing.invalid
# 自检按模式各探一条(通配符来源要换成一个具体子域, 那个字面值不会出现在 Host 头里)
probe_of() { local s=$1; [[ $s == \*.* ]] && s="probe.${s#*.}"; printf '%s' "$s"; }
entries=()
seen_modes=""
while IFS=$'\t' read -r src mode _upstream; do
  [[ " $seen_modes " == *" $mode "* ]] && continue
  seen_modes+=" $mode"
  entries+=("$mode:$src")
done < <(python3 render.py routes.conf --print-modes "${RT[@]}" 2>/dev/null || true)

# --max-time 留在 curl 参数里: 转发规则的探测会真的打到上游, 上游卡住时不能拖住 status
probe() { curl ${3:-} -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $1" "$2" 2>/dev/null || true; }
# 指纹探兜底块: 第一条规则可能是通配符或 IP, 那种字面 Host 永远不命中
live_ver() {  # $1=URL  $2=curl 额外参数(https 要 -k)
  { curl ${2:-} -sSI --noproxy '*' --max-time 3 -H "Host: $FALLBACK_HOST" "$1" 2>/dev/null || true; } \
    | tr -d '\r' | sed -n 's/^X-Rules-Version: //p'
}
shown() {
  local l
  l=$(ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd' ' -)
  printf '%s' "${l:-无($1 端口没有被监听)}"
}

do_status() {
  local disk live_http live_https want got_ok
  echo "服务:     $(systemctl is-active nginx 2>&1) (开机自启: $(systemctl is-enabled nginx 2>&1))"
  echo "站点配置: $ENABLED -> $(readlink "$ENABLED" 2>/dev/null || echo '未安装')"
  echo "监听:     HTTP  $PORT -> $(shown "$PORT")"
  if [[ -n $HTTPSPORT ]]; then
    echo "          HTTPS $HTTPSPORT -> $(shown "$HTTPSPORT")"
  else
    echo "          HTTPS: 未启用(这份配置是 HTTPS=off 渲染的)"
  fi
  echo "规则数:   $(grep -cvE '^\s*(#|$)' routes.conf || true) 条 (routes.conf)"

  disk=$(python3 render.py routes.conf --print-version "${RT[@]}" 2>/dev/null \
         || echo "<routes.conf 有错, 跑 ./deploy.sh 看详情>")
  live_http=$(live_ver "http://127.0.0.1:$PORT/")
  live_https=""
  echo "生效版本: HTTP  ${live_http:-<$PORT 端口无响应>}"
  if [[ -n $HTTPSPORT ]]; then
    live_https=$(live_ver "https://127.0.0.1:$HTTPSPORT/" -k)
    echo "          HTTPS ${live_https:-<$HTTPSPORT 端口无响应>}"
  fi
  echo "磁盘版本: $disk"

  want=$disk got_ok=1
  [[ $live_http == "$want" ]] || got_ok=0
  if [[ -n $HTTPSPORT && $live_https != "$want" ]]; then got_ok=0; fi
  if [[ -z $live_http ]]; then
    echo "结论:     服务没起来, 执行 ./start.sh"
  elif (( got_ok )); then
    echo "结论:     routes.conf 已完整生效"
  else
    echo "结论:     有改动未生效, 执行 ./start.sh reload"
  fi

  echo "自检:"
  for entry in "${entries[@]}"; do
    mode=${entry%%:*}; src=${entry#*:}; host=$(probe_of "$src")
    if [[ $mode == proxy ]]; then
      # 转发的状态码来自上游本身: 200/301/401 都算通, 502/504 说明上游没起来
      printf '  %-11s %-16s 命中         -> %s (转发: 上游没起来时 502)\n' \
        "HTTP:$PORT" "$mode:$src" "$(probe "$host" "http://127.0.0.1:$PORT/")"
    else
      printf '  %-11s %-16s 命中         -> %s (跳转: 期望 302)\n' \
        "HTTP:$PORT" "$mode:$src" "$(probe "$host" "http://127.0.0.1:$PORT/")"
    fi
  done
  printf '  %-11s %-16s 未配置 Host  -> %s (期望 400)\n' "HTTP:$PORT" "兜底" \
    "$(probe "$FALLBACK_HOST" "http://127.0.0.1:$PORT/")"
  if [[ -n $HTTPSPORT ]]; then
    printf '  %-11s %-16s 未配置 Host  -> %s (期望 400)\n' "HTTPS:$HTTPSPORT" "兜底" \
      "$(probe "$FALLBACK_HOST" "https://127.0.0.1:$HTTPSPORT/" -k)"
  fi
  echo "证书:"
  ./ssl.sh status 2>&1 | sed 's/^/  /'
  echo "最近日志:"
  sudo tail -n 3 /var/log/nginx/hostproxy.access.log 2>/dev/null | sed 's/^/  /' || echo "  (读不到日志文件)"
}

case "$cmd" in
  start|reload)
    ./deploy.sh
    ;;
  restart)
    ./deploy.sh            # 先校验写盘, 配置有问题时 deploy.sh 会回滚并且不往下走
    sudo systemctl restart nginx
    echo "nginx 已完全重启。"
    ;;
  stop)
    echo "即将停止 nginx —— 本机所有由 nginx 承载的站点都会下线。"
    sudo systemctl stop nginx
    echo "已停止, 80/443 端口释放。开机自启状态未改动(用 sudo systemctl disable nginx 取消)。"
    ;;
  status)
    do_status
    ;;
  *)
    echo "未知子命令: $cmd (见 --help)" >&2
    exit 2
    ;;
esac
