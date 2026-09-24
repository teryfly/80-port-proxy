#!/usr/bin/env bash
# routes.conf -> 渲染 -> 补证书 -> 装到 nginx -> 校验, 失败则回滚。
# HTTP 和 HTTPS 同时生效: 443 只在 TLS 握手上多一层, 302/400 的行为和 80 端口完全一致。
set -euo pipefail
cd "$(dirname "$0")"

AVAIL=/etc/nginx/sites-available/hostproxy.conf
ENABLED=/etc/nginx/sites-enabled/hostproxy.conf
DEFAULT_ENABLED=/etc/nginx/sites-enabled/default
DEFAULT_AVAIL=/etc/nginx/sites-available/default
BAK=build/hostproxy.conf.bak
PORT=${PORT:-80}          # PORT=8080 ./deploy.sh 可换端口试跑, 无需 root 也能起
HTTPSPORT=${HTTPSPORT:-443}
HTTPS=${HTTPS:-on}        # HTTPS=off 只渲染 80, 一条 TLS 指令都不出

sudo -n true || { echo "需要 sudo(免密)权限" >&2; exit 1; }
mkdir -p build

# 证书目录只在 render.py 里定义一份, 这里读出来分发给 render 和 ssl.sh
CERTS_DIR=$(python3 render.py --print-defaults | sed -n 's/^CERTS_DIR_DEFAULT=//p')
export CERTS_DIR
RT=(--port "$PORT" --certs-dir "$CERTS_DIR")
if [[ $HTTPS == off ]]; then
  RT+=(--no-https)
else
  RT+=(--https-port "$HTTPSPORT")
fi

python3 render.py routes.conf -o build/hostproxy.conf "${RT[@]}"

# 渲染是纯函数, 不去猜证书存不存在; 但 nginx -t 会. 所以装盘之前必须保证文件到位,
# 否则一份好配置会因为缺证书被当成校验失败回滚掉。
if [[ $HTTPS != off ]]; then
  ./ssl.sh ensure || { echo "证书准备失败, 没有动 nginx 的配置" >&2; exit 1; }
fi

if [[ -f $AVAIL ]]; then
  sudo cp "$AVAIL" "$BAK"
else
  rm -f "$BAK"
fi
HAD_DEFAULT=0
if [[ -L $DEFAULT_ENABLED ]]; then
  HAD_DEFAULT=1
fi

restore() {
  echo "nginx 校验未通过, 回滚到上次配置" >&2
  if [[ -f $BAK ]]; then
    sudo cp "$BAK" "$AVAIL"
    sudo ln -sfn "$AVAIL" "$ENABLED"
  else
    sudo rm -f "$AVAIL" "$ENABLED"
  fi
  # nginx 自带站点也声明 default_server, 只有在我们自己那份被彻底摘掉时才把它放回去;
  # 两份同时在 sites-enabled 里会让下面这句 nginx -t 必然失败, 回滚就等于没回滚。
  if (( HAD_DEFAULT )) && [[ ! -f $BAK ]]; then
    sudo ln -sfn "$DEFAULT_AVAIL" "$DEFAULT_ENABLED"
  fi
  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx || true
  else
    echo "回滚后的配置仍然校验失败, 需要手工处理: sudo nginx -t" >&2
  fi
  exit 1
}

sudo cp build/hostproxy.conf "$AVAIL"
sudo ln -sfn "$AVAIL" "$ENABLED"
# nginx 自带站点同样声明 default_server, 会和兜底 400 那块冲突。卸掉链接, 文件保留。
if [[ -L $DEFAULT_ENABLED ]]; then
  sudo rm -f "$DEFAULT_ENABLED"
fi

if ! sudo nginx -t; then
  restore
fi
# 服务没跑时 reload 会失败, 这种情况直接拉起来。
if systemctl is-active --quiet nginx; then
  sudo systemctl reload nginx
  echo "已 reload, 配置生效。"
else
  sudo systemctl start nginx
  echo "nginx 原本未运行, 已 start, 配置生效。"
fi

# reload 是异步的, 旧 worker 还会用上一个配置应答一小会儿。配置指纹写进了响应头,
# 所以拿它比对才知道新规则到底生效没有。指纹探测走兜底块: 第一条规则可能是通配符或 IP,
# 那种字面 Host 永远不命中, 拿它探会一直读到兜底块的值, 反而看不出问题。
ver=$(python3 render.py routes.conf --print-version "${RT[@]}")
first=$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' routes.conf)
FALLBACK_HOST=probe-missing.invalid
# 通配符规则要拿一个具体子域去探, "*.foo.com" 本身不会成为任何请求的 Host
probe_host=$first
[[ $probe_host == \*.* ]] && probe_host="probe.${probe_host#*.}"

# -w 里的 %{http_code} 需要 curl 参数拼接, $3 留空时不加任何参数
probe() { curl ${3:-} -sS --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $1" "$2" || true; }
# TLS 侧要真的把 SNI 发出去才算模拟了浏览器: --resolve 让 curl 拿域名握手却仍连本机
probe_tls() { curl -ksS --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' \
                   --resolve "$1:$HTTPSPORT:127.0.0.1" "$2" || true; }
live_ver() {  # $1=URL  $2=curl 额外参数(https 要 -k)
  { curl ${2:-} -sSI --noproxy '*' -H "Host: $FALLBACK_HOST" "$1" 2>/dev/null || true; } \
    | tr -d '\r' | sed -n 's/^X-Rules-Version: //p'
}
is_ipv4() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

http_url=http://127.0.0.1:$PORT/
https_url=https://127.0.0.1:$HTTPSPORT/
# 两个端口的应答指纹都等于期望版本, 才说明 reload 真的落地了
uptodate() {
  [[ $(live_ver "$http_url") == "$ver" ]] || return 1
  if [[ $HTTPS != off ]]; then
    [[ $(live_ver "$https_url" -k) == "$ver" ]] || return 1
  fi
  return 0
}
for _ in $(seq 25); do
  uptodate && break
  sleep 0.2
done
uptodate || echo "警告: nginx 仍在跑旧配置, 期望版本 $ver" >&2

echo "自检 (配置版本 $ver, HTTP $PORT, HTTPS $( [[ $HTTPS == off ]] && echo off || echo "$HTTPSPORT" ), 探测域名: $probe_host):"
printf '  %-11s 命中          -> %s\n'           "HTTP:$PORT" "$(probe "$probe_host" "$http_url")"
printf '  %-11s 带路径查询串  -> %s\n'           "HTTP:$PORT" "$(probe "$probe_host" "${http_url}some/path?a=1&b=2")"
printf '  %-11s 未配置 Host   -> %s (期望 400)\n' "HTTP:$PORT" "$(probe "$FALLBACK_HOST" "$http_url")"
if [[ $HTTPS != off ]]; then
  if is_ipv4 "$probe_host"; then
    # IP 来源的 HTTPS 请求不发 SNI, 握手一定落在兜底块上, 没法用 curl 模拟出真实访客的路径
    printf '  %-11s IP 来源      -> 跳过(客户端对 IP 不发 SNI, 只会落到兜底块)\n' "HTTPS:$HTTPSPORT"
  else
    printf '  %-11s 命中(SNI)    -> %s\n' "HTTPS:$HTTPSPORT" "$(probe_tls "$probe_host" "https://$probe_host:$HTTPSPORT/")"
    printf '  %-11s 带路径查询串 -> %s\n' "HTTPS:$HTTPSPORT" "$(probe_tls "$probe_host" "https://$probe_host:$HTTPSPORT/some/path?a=1&b=2")"
  fi
  printf '  %-11s 未配置 Host   -> %s (期望 400)\n' "HTTPS:$HTTPSPORT" "$(probe "$FALLBACK_HOST" "$https_url" -k)"
fi
