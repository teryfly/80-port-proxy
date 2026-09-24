#!/usr/bin/env bash
# 一次性安装: 检查依赖 -> 装 nginx -> 应用 routes.conf -> 询问是否开机自启。
# 可重复执行。
#
# 用法: ./install.sh [--enable-boot | --no-enable-boot]
#   --enable-boot     设置 nginx 开机自启(不问)
#   --no-enable-boot  关掉 nginx 开机自启(不问)
#   不加参数且有终端时会交互询问; 非交互环境(如管道/CI)只跳过这一步并给出提示。
set -euo pipefail
cd "$(dirname "$0")"

BOOT=""
for arg in "$@"; do
  case "$arg" in
    --enable-boot)    BOOT=yes ;;
    --no-enable-boot) BOOT=no ;;
    -h|--help)        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg (见 --help)" >&2; exit 2 ;;
  esac
done

sudo -n true || { echo "需要 root 或免密 sudo" >&2; exit 1; }

echo "== 1/4 依赖检查 =="
for cmd in python3 curl awk openssl; do
  command -v "$cmd" >/dev/null || { echo "缺少命令: $cmd, 请先 apt install $cmd" >&2; exit 1; }
done
echo "  python3 $(python3 -V 2>&1 | cut -d' ' -f2), curl/awk/openssl 就绪"

echo "== 2/4 nginx =="
if command -v nginx >/dev/null; then
  echo "  已安装: $(nginx -v 2>&1 | cut -d/ -f2)"
else
  echo "  未安装, 正在 apt 安装 nginx(会创建 /etc/nginx 与 nginx.service)..."
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
  echo "  安装完成: $(nginx -v 2>&1 | cut -d/ -f2)"
fi

echo "== 3/4 应用 routes.conf =="
./deploy.sh

echo "== 4/4 开机自启 =="
current=$(systemctl is-enabled nginx 2>&1 || true)
case "$BOOT" in
  yes)
    sudo systemctl enable nginx >/dev/null 2>&1
    echo "  已开启 nginx 开机自启"
    ;;
  no)
    sudo systemctl disable nginx 2>&1 | sed 's/^/  /'
    echo "  已关闭 nginx 开机自启(下次开机 80/443 端口不再自动接管, 需要手动 ./start.sh)"
    ;;
  *)
    if [[ -t 0 ]]; then
      printf "  是否把 nginx 加入开机自启? 当前状态: %s [Y/n] " "$current"
      # Ctrl-D 时 read 返回非零, 不吃掉这个状态会让 set -e 中断整个安装
      read -r reply || reply=""
      case "${reply:-Y}" in
        [Yy]*) sudo systemctl enable nginx >/dev/null 2>&1; echo "  已开启" ;;
        [Nn]*) sudo systemctl disable nginx 2>&1 | sed 's/^/  /'; echo "  已关闭" ;;
        *)     echo "  未改动, 保持 $current" ;;
      esac
    else
      echo "  非交互环境, 跳过询问。当前状态: $current"
      echo "  需要变更用: sudo systemctl enable nginx   (或 ./install.sh --enable-boot)"
    fi
    ;;
esac

echo
echo "安装完成。"
echo "  改动 routes.conf 后生效:  ./deploy.sh   或   ./start.sh reload"
echo "  查看运行状态:              ./start.sh status"
echo "  访问日志:                  sudo tail -f /var/log/nginx/hostproxy.access.log"
echo "  HTTPS: 现在用的是现签的自签证书(功能正常, 浏览器会告警)。要看每个来源的证书 ./ssl.sh status,"
echo "         想换成 Let's Encrypt 受信证书: sudo apt-get install -y certbot && ./ssl.sh le <精确域名>"
echo "  防火墙: 443 要和 80 一起放行 —— 云服务器安全组入方向 TCP 443, 本机 ufw 则 sudo ufw allow 443/tcp"
[[ $(systemctl is-enabled nginx 2>&1 || true) == enabled ]] || echo "  注意: nginx 未设开机自启, 重启机器后需手动 ./start.sh"
