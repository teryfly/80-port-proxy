#!/usr/bin/env bash
# HTTPS 证书管理。deploy.sh 只会调 `ensure`, 其余子命令按需手工执行。
#
# 用法: ./ssl.sh [ensure|le [域名...]|status|install-renew-timer]
#   ensure               保证 routes.conf 每个来源(以及兜底块)都有能用的证书, 缺就现签一张自签的。
#                        幂等, 不碰已经好用的证书, 也不碰 certbot。deploy.sh 在 nginx -t 之前调它。
#   le [域名...|--all]   为**精确域名**换成 Let's Encrypt 受信证书(webroot HTTP-01), 需要自己装 certbot。
#   status               每个来源用的哪张证书、受信与否、还剩几天。
#   install-renew-timer  装 systemd 定时器每天 renew + reload nginx。可选, 签了 LE 证书才需要。
#
# 自签证书功能完全正常, 但浏览器一定告警(要么手动信任一次)。通配符来源的受信证书只能走 DNS-01, 这里不签。
# 想用自己的证书: 把 $CERTS_DIR/<证书目录>/{fullchain.pem,privkey.pem} 换成你的文件即可, ensure 认得出来。
set -euo pipefail
cd "$(dirname "$0")"

ROUTES=${ROUTES:-routes.conf}
# 路径常量只在 render.py 里定义一份
defaults=$(python3 render.py --print-defaults)
eval "$defaults"
CERTS_DIR=${CERTS_DIR:-$CERTS_DIR_DEFAULT}
ACME_ROOT=${ACME_ROOT:-$ACME_ROOT_DEFAULT}
DAYS=${DAYS:-825}                      # 自签证书有效期(天)
RENEW_AHEAD=${RENEW_AHEAD:-864000}     # 剩余不足 10 天就重签
LE_LIVE=/etc/letsencrypt/live

NAMES=()    # 有序: 需要准备哪些证书目录
SRCS=()     # 与 NAMES 同下标: 该目录对应的来源, 兜底块是 "-"
declare -A DIR_OF    # 来源 -> 目录名

load_map() {
  [[ -f $ROUTES ]] || { echo "找不到 $ROUTES" >&2; return 1; }
  local name src
  NAMES=(); SRCS=(); DIR_OF=()
  while IFS=$'\t' read -r name src; do
    NAMES+=("$name"); SRCS+=("$src"); DIR_OF["$src"]="$name"
  done < <(python3 render.py "$ROUTES" --print-cert-names)
  (( ${#NAMES[@]} )) || { echo "没解析出证书目录名, $ROUTES 大概有错" >&2; return 1; }
}

need_sudo() { sudo -n true || { echo "需要 root 或免密 sudo" >&2; return 1; }; }
dir_of() { printf '%s/%s\n' "$CERTS_DIR" "$1"; }
is_ipv4() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 证书在、能解析、私钥配得上、且没临近过期 —— 满足就不重签
usable() {  # $1=目录名
  local d a b
  d=$(dir_of "$1")
  [[ -f $d/fullchain.pem && -f $d/privkey.pem ]] || return 1   # -f 跟软链, 断掉的 LE 软链在这一步被判死
  openssl x509 -in "$d/fullchain.pem" -noout -checkend "$RENEW_AHEAD" >/dev/null 2>&1 || return 1
  a=$(openssl x509 -in "$d/fullchain.pem" -noout -pubkey 2>/dev/null | sha256sum | cut -c1-16)
  b=$(sudo openssl pkey -in "$d/privkey.pem" -pubout 2>/dev/null | sha256sum | cut -c1-16)
  [[ -n $a && $a == "$b" ]]
}

# SAN 里是否写着这个来源。只用于告警: 手工放的证书可能故意用别的名字, 不能因此把人删了
covers() {  # $1=目录名 $2=来源
  local san want
  [[ $2 == "-" ]] && return 0     # 兜底块不对应任何 server_name, 没得校验
  san=$(openssl x509 -in "$(dir_of "$1")/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')
  # openssl 把 IP _SAN 打成 "IPAddress:1.2.3.4", 不是 "IP:"
  if is_ipv4 "$2"; then want="IPAddress:$2"; else want="DNS:$2"; fi
  grep -qF -- "$want" <<<"$san"
}

sign_selfsigned() {  # $1=目录名 $2=来源
  local d cn san
  d=$(dir_of "$1")
  if [[ $2 == "-" ]]; then
    cn="hostproxy-fallback"; san="DNS:localhost"
  elif is_ipv4 "$2"; then
    cn="$2"; san="IP:$2"
  else
    cn="$2"; san="DNS:$2"      # 通配符来源照原样签: DNS:*.foo.com
  fi
  sudo mkdir -p "$d"
  # 目录和证书本身不设防(证书是公开信息), 只有私钥 0600。
  # 全塞 0700 的话, 非 root 的 usable/status 就看不见文件, ensure 每次都会重签。
  sudo chmod 755 "$d"
  # 先写 .new 再 mv 就位, 不让 nginx 读到半截文件
  if ! sudo openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$d/privkey.pem.new" -out "$d/fullchain.pem.new" \
      -days "$DAYS" -subj "/CN=$cn" \
      -addext "subjectAltName=$san" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=serverAuth" 2>/dev/null; then
    sudo rm -f "$d/privkey.pem.new" "$d/fullchain.pem.new"
    echo "openssl 签证书失败: $1" >&2
    return 1
  fi
  sudo chmod 600 "$d/privkey.pem.new"
  sudo chmod 644 "$d/fullchain.pem.new"
  sudo mv -f "$d/privkey.pem.new" "$d/privkey.pem"
  sudo mv -f "$d/fullchain.pem.new" "$d/fullchain.pem"
  echo "  现签一张自签证书: $1 (CN=$cn)"
}

do_ensure() {
  need_sudo || return 1
  load_map || return 1
  sudo mkdir -p "$CERTS_DIR" "$ACME_ROOT"
  sudo chmod 755 "$CERTS_DIR"
  sudo chmod 755 "$ACME_ROOT"        # www-data 要能读 ACME 挑战文件
  local i made=0
  for i in "${!NAMES[@]}"; do
    if usable "${NAMES[$i]}"; then
      if ! covers "${NAMES[$i]}" "${SRCS[$i]}"; then
        echo "  提示: ${NAMES[$i]} 的证书 SAN 里没有 ${SRCS[$i]}, 访客会看到名称不匹配告警(不动它, 可能是手工放的)"
      fi
    else
      sign_selfsigned "${NAMES[$i]}" "${SRCS[$i]}" || return 1
      made=1
    fi
  done
  (( made )) || echo "证书齐了, 没动 $CERTS_DIR"
}

# routes.conf 里能签受信证书的来源: 精确域名(排除通配符、IP、兜底块)
le_targets() {
  local i
  for i in "${!SRCS[@]}"; do
    if [[ ${SRCS[$i]} != "-" && ${SRCS[$i]} != \*.* ]] && ! is_ipv4 "${SRCS[$i]}"; then
      printf '%s\n' "${SRCS[$i]}"
    fi
  done
}

link_le() {  # $1=来源
  local name d
  name=${DIR_OF[$1]}; d=$(dir_of "$name")
  [[ -f $LE_LIVE/$1/fullchain.pem && -f $LE_LIVE/$1/privkey.pem ]] \
    || { echo "$LE_LIVE/$1 里没有证书" >&2; return 1; }
  # 只换这两个软链, 不 rm -rf 整个目录, 免得把用户自己放进去的文件带走。
  # 续期时 certbot 原地更新 live/ 里的软链目标, 所以这里指过去就不用再管了。
  sudo mkdir -p "$d"
  sudo ln -sfn "$LE_LIVE/$1/fullchain.pem" "$d/fullchain.pem"
  sudo ln -sfn "$LE_LIVE/$1/privkey.pem"   "$d/privkey.pem"
  echo "  $1 -> 已换成 Let's Encrypt 证书 ($name)"
}

do_le() {
  need_sudo || return 1
  load_map || return 1
  command -v certbot >/dev/null \
    || { echo "certbot 未安装, 本项目不自动装。需要时执行: sudo apt-get install -y certbot" >&2; return 1; }

  local -a want=()
  if [[ ${1:-} == --all || $# -eq 0 ]]; then
    mapfile -t want < <(le_targets)
    (( ${#want[@]} )) || { echo "$ROUTES 里没有可签发的精确域名"; return 0; }
  else
    want=("$@")
  fi

  local src rc=0
  for src in "${want[@]}"; do
    if [[ $src == \*.* ]]; then
      echo "跳过 $src: 泛域名的受信证书只能走 DNS-01(要 DNS 服务商凭据), webroot 签不了。继续用自签。"
      rc=1; continue
    fi
    if is_ipv4 "$src"; then
      echo "跳过 $src: IP 访问不发 SNI, 握手落在兜底块上, 给它签发没有意义。"
      rc=1; continue
    fi
    if [[ -z ${DIR_OF[$src]:-} ]]; then
      echo "跳过 $src: 它不是 $ROUTES 里的来源"
      rc=1; continue
    fi
    local -a extra=()
    if [[ -n ${EMAIL:-} ]]; then extra=(--non-interactive --agree-tos -m "$EMAIL"); fi
    echo "签发 $src (挑战文件放 $ACME_ROOT, 由 80 端口提供)"
    if ! sudo certbot certonly --webroot -w "$ACME_ROOT" -d "$src" "${extra[@]}"; then
      echo "  certbot 失败, $src 保持原证书。常见原因: DNS 没指到本机、安全组没放行 80、触发速率限制" >&2
      rc=1; continue
    fi
    link_le "$src" || rc=1
  done

  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
    echo "nginx 已 reload。"
  else
    echo "nginx 校验没通过, 没有 reload。跑 sudo nginx -t 看详情" >&2
    return 1
  fi
  return "$rc"
}

do_status() {
  load_map || return 1
  local i d src issuer end left trust
  printf '证书目录: %s\n' "$CERTS_DIR"
  printf '%-24s %-6s %-7s %s\n' "来源" "信任" "剩余" "证书目录"
  for i in "${!NAMES[@]}"; do
    src=${SRCS[$i]}; d=$(dir_of "${NAMES[$i]}")
    if [[ ! -f $d/fullchain.pem ]]; then
      printf '%-24s %-6s %-7s %s\n' "$src" "缺失" "-" "${NAMES[$i]}"
      continue
    fi
    issuer=$(openssl x509 -in "$d/fullchain.pem" -noout -issuer | sed 's/^issuer= //')
    end=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate | cut -d= -f2)
    left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if [[ $issuer == *"ISRG"* || $issuer == *"Let's Encrypt"* ]]; then trust="受信"; else trust="自签"; fi
    printf '%-24s %-6s %-7s %s\n' "$src" "$trust" "${left}天" "${NAMES[$i]}"
    covers "${NAMES[$i]}" "$src" || printf '    ^ SAN 里没有 %s\n' "$src"
  done
  if command -v certbot >/dev/null; then
    printf 'certbot: 已安装, 可以 ./ssl.sh le 换受信证书\n'
  else
    printf 'certbot: 未安装, 现在全是自签证书(浏览器会告警)\n'
  fi
}

do_timer() {
  need_sudo || return 1
  command -v certbot >/dev/null || { echo "certbot 未安装, 定时器没有意义" >&2; return 1; }
  local s=/etc/systemd/system/hostproxy-renew.service t=/etc/systemd/system/hostproxy-renew.timer
  {
    printf '%s\n' '[Unit]' 'Description=Renew the Let'"'"'s Encrypt certs used by hostproxy' '' \
      '[Service]' 'Type=oneshot' \
      'ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "/usr/bin/systemctl reload nginx"'
  } | sudo tee "$s" >/dev/null
  {
    printf '%s\n' '[Unit]' 'Description=Daily renew attempt for hostproxy certs' '' '[Timer]' \
      'OnCalendar=daily' 'RandomizedDelaySec=3h' 'Persistent=true' '' \
      '[Install]' 'WantedBy=timers.target'
  } | sudo tee "$t" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now hostproxy-renew.timer
  echo "已装定时器 $t"
  echo "nginx 换证书必须 reload 才生效, 所以 --deploy-hook 里带了 reload nginx"
  echo "卸载: sudo systemctl disable --now hostproxy-renew.timer && sudo rm -f $s $t"
}

cmd=${1:-ensure}
if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  -h|--help)           sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  ensure)              do_ensure "$@" ;;
  le)                  do_le "$@" ;;
  status)              do_status "$@" ;;
  install-renew-timer) do_timer "$@" ;;
  *) echo "未知子命令: $cmd (见 --help)" >&2; exit 2 ;;
esac
