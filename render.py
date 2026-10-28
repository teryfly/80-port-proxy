#!/usr/bin/env python3
"""把 routes.conf 渲染成 nginx server 块。

规则的目标落在本机就走内部转发(proxy_pass, 访客地址栏不变, 只连 80/443),
目标在别的机器就返回 302。判定见 classify()。

用法: python3 render.py [routes.conf] [-o 输出文件] [--port 80] [--https-port 443]
                        [--stdout] [--print-version] [--print-cert-names] [--print-modes]
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import re
import socket
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

DEFAULT_CERTS_DIR = "/etc/nginx/certs/hostproxy"
DEFAULT_PORT = 80
DEFAULT_HTTPS_PORT = 443
# HTTP-01 校验文件的根目录, ssl.sh 和 acme_block() 共用同一个默认值
ACME_ROOT = "/var/www/letsencrypt"
# 兜底 400 那块(以及不带 SNI 的连接)用的证书目录
DEFAULT_CERT = "_default"

# 精确域名 / *.通配符 / 裸IP（字符类里刻意不含下划线, 主机名带它基本是笔误）
SOURCE_RE = re.compile(r"^(?:\*\.)?[A-Za-z0-9][A-Za-z0-9.-]*$")
# nginx 会展开 return 参数里的 $var, 且这些字符会破坏配置行的引号/分号结构
FORBIDDEN = set("\"'$`;\\ \t")
# 证书目录名保留前缀: 来源写法不允许出现 "_", 所以这两个前缀不可能和真实来源撞名
WILDCARD_PREFIX = "_w."


class ConfigError(Exception):
    pass


def cert_name(source: str) -> str:
    """来源 -> 证书目录名。`*.foo.com` 换成 `_w.foo.com`, 其余原样。"""
    return WILDCARD_PREFIX + source[2:] if source.startswith("*.") else source


def is_ip(source: str) -> bool:
    try:
        ipaddress.ip_address(source)
    except ValueError:
        return False
    return True


def parse(source: Path) -> list[tuple[str, str, int]]:
    rules: list[tuple[str, str, int]] = []
    seen: dict[str, int] = {}

    for lineno, raw in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ConfigError(f"第 {lineno} 行: 需要「来源 目标」两列, 实际 {len(parts)} 列 -> {raw!r}")
        host, target = parts

        if not SOURCE_RE.match(host):
            raise ConfigError(f"第 {lineno} 行: 来源写法不合法 -> {host!r}")
        if "*" in host and not host.startswith("*."):
            raise ConfigError(f"第 {lineno} 行: 通配符只能放在最前面, 如 *.example.com -> {host!r}")
        if host in seen:
            raise ConfigError(f"第 {lineno} 行: 来源 {host} 与第 {seen[host]} 行重复")

        if not target.startswith(("http://", "https://")):
            raise ConfigError(f"第 {lineno} 行: 目标必须以 http:// 或 https:// 开头 -> {target!r}")
        bad = FORBIDDEN & set(target)
        if bad:
            raise ConfigError(f"第 {lineno} 行: 目标含有非法字符 {sorted(bad)} -> {target!r}")
        parts_url = urlsplit(target)
        if not parts_url.netloc:
            raise ConfigError(f"第 {lineno} 行: 目标缺少主机名 -> {target!r}")
        try:
            # 只为了触发 urlsplit 对端口的校验, 如 http://h:80a
            parts_url.port
        except ValueError as e:
            raise ConfigError(f"第 {lineno} 行: 目标端口不合法 -> {target!r}") from e

        # 结尾多余的 / 会让跳转结果出现 //, 统一去掉
        target = target.rstrip("/") or target
        seen[host] = lineno
        rules.append((host, target, lineno))

    if not rules:
        raise ConfigError("一条规则都没有, 那样所有请求都会返回 400")
    return rules


def is_local_ip(ip: str) -> bool:
    """这个 IP 是不是本机的: 能 bind 上就是。比解析网卡文本可靠, 也不引外部命令。

    0.0.0.0/:: 也能 bind 成功, 但它表示"任意地址", 当作目标写出来是笔误, 按非本机处理。
    """
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if addr.is_unspecified:
        return False
    fam = socket.AF_INET6 if addr.version == 6 else socket.AF_INET
    sock = socket.socket(fam, socket.SOCK_STREAM)
    try:
        sock.bind((ip, 0))
    except OSError:
        return False
    finally:
        sock.close()
    return True


def resolve_ips(host: str) -> list[str]:
    """域名 -> 确定性排序的 IP 列表(loopback 优先); 解析不了就返回空列表。"""
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return []
    addrs = {info[4][0].split("%", 1)[0] for info in infos}
    return sorted(addrs, key=lambda a: (0 if ipaddress.ip_address(a).is_loopback else 1,
                                         ipaddress.ip_address(a).packed))


def netloc(host: str, port: int | None) -> str:
    """拼 nginx 认的 host:port, IPv6 补方括号。"""
    literal = f"[{host}]" if ":" in host else host
    return literal if port is None else f"{literal}:{port}"


def classify(rules: list[tuple[str, str, int]], opts: dict) -> list[dict]:
    """给每条规则定模式。目标是本机 -> 内部转发; 别的机器 -> 302; 拿不准也 302。

    判"本机"有两条依据, 命中任一条即可:
      1. 目标 IP 能 bind(在网卡上或 loopback)。
      2. 目标 IP 与该来源域名解析到的 IP 相同。云上公网 IP 是 provider 做的 NAT,
         不在任何网卡上、bind 不上, 但 `THEA.fhir.press -> :5268` 正是这种"同 IP 换端口"。
    解析失败一律按 302 处理: 那是本程序改动前的行为, 不能让 DNS 抖动把 deploy 拖回滚。
    """
    plans: list[dict] = []
    listen_ports = {opts["port"]}
    if opts["https"]:
        listen_ports.add(opts["https_port"])

    for host, target, lineno in rules:
        url = urlsplit(target)
        scheme = url.scheme
        declared_host = url.hostname or ""
        port = url.port or (443 if scheme == "https" else 80)
        prefix = url.path.rstrip("/")
        declared = f"{scheme}://{netloc(declared_host, url.port)}"
        plan = {"host": host, "target": target, "lineno": lineno, "mode": "redirect",
                "upstream": None, "prefix": prefix, "declared": declared,
                "declared_host": declared_host,
                "scheme": scheme, "port": port, "why": "目标不在本机"}

        ips = resolve_ips(declared_host)
        local = [ip for ip in ips if is_local_ip(ip)]
        same_origin = (not host.startswith("*.") and not is_ip(host)
                       and declared_host == host.lower())
        if not local and ips:
            # 通配符和裸 IP 来源不参与同 IP 判定: 那个字面值永远不会成为请求里的 Host
            same_origin = same_origin or bool(set(ips) & set(resolve_ips(host)))

        if local or same_origin:
            if port in listen_ports:
                raise ConfigError(
                    f"第 {lineno} 行: 目标端口 {port} 就是本程序监听的端口, 转发会打回自己形成自环 -> {target!r}")
            # bind 得到的地址原样用(服务只绑某张网卡时也连得上); 只靠同 IP 认定的
            # NAT 公网地址改写成 loopback, 让流量不出主机, 也就不依赖安全组放行该端口。
            fallback = "::1" if ips and ":" in ips[0] else "127.0.0.1"
            up_host = local[0] if local else fallback
            plan.update(mode="proxy", upstream=f"{scheme}://{netloc(up_host, port)}",
                        why="本机可达" if local else "与来源同 IP")
        plans.append(plan)
    return plans


def version_of(config: Path, opts: dict) -> str:
    """生效配置的指纹, 写进响应头, 用来判断 nginx 是否已换到新配置。

    必须把端口/证书目录这些渲染参数一起哈希: 只改 --https-port 时 routes.conf
    字节没变, 但线上配置确实变了, 光哈希文件会让 deploy.sh 的轮询误判成"已生效"。
    """
    digest = hashlib.sha256(config.read_bytes())
    digest.update(b"\0")
    digest.update(f"{opts['port']},{opts['https']},{opts['https_port']},{opts['certs_dir']}".encode())
    return digest.hexdigest()[:12]


def tls_directives(certs_dir: str, name: str) -> list[str]:
    return [
        f"    ssl_certificate {certs_dir}/{name}/fullchain.pem;",
        f"    ssl_certificate_key {certs_dir}/{name}/privkey.pem;",
        "    ssl_protocols TLSv1.2 TLSv1.3;",
        "    ssl_ciphers HIGH:!aNULL:!MD5;",
        # 共享内存池的名字必须在所有 server 里完全一致, 否则 nginx 直接报冲突
        "    ssl_session_cache shared:HOSTPROXY:10m;",
        "    ssl_session_timeout 1d;",
    ]


def acme_block() -> str:
    """HTTP-01 校验用的路径。

    必须放在 location / 之前吗? 不需要——nginx 按最长前缀匹配, /.well-known/...
    比 / 长, 所以这里的 token 不会被下面那条规则(302 或 proxy_pass)抢走。^~ 是防以后加正则 location。
    """
    return "\n".join([
        "    location ^~ /.well-known/acme-challenge/ {",
        f"        root {ACME_ROOT};",
        "        default_type text/plain;",
        "        try_files $uri =404;",
        "    }",
    ])


# 转发块里跟 WebSocket/SSE 无关、纯粹是"nginx 现在真的经手请求和响应了"必须补的东西
PROXY_COMMON = [
    "        proxy_http_version 1.1;",
    "        proxy_set_header Upgrade $http_upgrade;",
    "        proxy_set_header Connection $hostproxy_upgrade;",
    "        proxy_set_header Host $host;",
    "        proxy_set_header X-Real-IP $remote_addr;",
    "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
    "        proxy_set_header X-Forwarded-Proto $scheme;",
    "        proxy_set_header X-Forwarded-Host $host;",
    # 302 时代 nginx 不经手请求体, 没有这个限制; 不写 0 就是默认 1m, 大 POST 会被挡成 413。
    # 0 必须配上下面的请求体不缓冲, 否则任意大的 body 会写满 client_body_temp。
    "        client_max_body_size 0;",
    "        proxy_request_buffering off;",
    "        proxy_connect_timeout 5s;",
]


def proxy_location(plan: dict) -> list[str]:
    lines = ["    location / {"]
    if plan["prefix"]:
        # 带变量时 nginx 不做 location 前缀替换, 而是把未归一化的原始请求 URI 接在前缀后面,
        # 这样 %2F/%3F 和 // 都不会被改写, 与 302 时代的"加前缀"逐字节一致。
        lines.append(f'        proxy_pass {plan["upstream"]}{plan["prefix"]}$request_uri;')
    else:
        lines.append(f'        proxy_pass {plan["upstream"]};')
    lines += PROXY_COMMON
    # 上游常回绝对地址(HAPI/FHIR 尤其爱这么干), 不重写就把 loopback 送到公网访客的浏览器里。
    forms = {plan["declared"], plan["upstream"]}
    for form in sorted(forms):
        lines.append(f"        proxy_redirect {form}/ /;")
    if plan["scheme"] == "https":
        lines += [
            "        proxy_ssl_server_name on;",
            f'        proxy_ssl_name {plan["declared_host"]};',
            "        proxy_ssl_verify off;",
        ]
    lines.append("    }")
    return lines


def render(plans: list[dict], opts: dict, ver: str) -> str:
    port, https_port, certs_dir = opts["port"], opts["https_port"], opts["certs_dir"]
    header = f'    add_header X-Rules-Version "{ver}" always;'
    out: list[str] = [
        f"# 由 render.py 从 routes.conf 自动生成, 不要手工编辑。版本 {ver}",
        f"# hostproxy-port: {port}",
        f"# hostproxy-https-port: {https_port if opts['https'] else 'off'}",
        f"# hostproxy-certs-dir: {certs_dir}",
        "log_format hostproxy '$time_iso8601 host=\"$host\" port=$server_port req=\"$request\" -> $status';",
    ]
    if any(p["mode"] == "proxy" for p in plans):
        # map 必须在 http 上下文, 而本文件正是被 include 在 http 里的, 所以放这儿合法。
        # 整份配置只出现一次: 同名 map 定义两遍 nginx -t 直接失败。
        out += [
            "",
            "# WebSocket 升级: 非升级请求要发 Connection: close",
            "map $http_upgrade $hostproxy_upgrade {",
            "    default upgrade;",
            "    ''      close;",
            "}",
        ]
    out += [
        "",
        "# 没匹配到任何来源时的兜底: 400",
        "server {",
        f"    listen {port} default_server;",
        f"    listen [::]:{port} default_server;",
    ]
    if opts["https"]:
        out += [
            f"    listen {https_port} ssl default_server;",
            f"    listen [::]:{https_port} ssl default_server;",
        ] + tls_directives(certs_dir, DEFAULT_CERT)
    out += [
        "    server_name _;",
        "    access_log /var/log/nginx/hostproxy.access.log hostproxy;",
        header,
        "    default_type text/plain;",
        acme_block(),
        "    location / {",
        '        return 400 \'bad request: Host "$host" is not configured in routes.conf\\n\';',
        "    }",
        "}",
    ]

    for plan in plans:
        host, target = plan["host"], plan["target"]
        shown = target if plan["mode"] == "redirect" else f"{plan['upstream']}{plan['prefix']}"
        out += [
            "",
            f"# {host}  ->  {target}  [{'转发 ' + shown if plan['mode'] == 'proxy' else '跳转'}]",
            "server {",
            f"    listen {port};",
            f"    listen [::]:{port};",
        ]
        if opts["https"]:
            out += [
                f"    listen {https_port} ssl;",
                f"    listen [::]:{https_port} ssl;",
            ] + tls_directives(certs_dir, cert_name(host))
        out += [
            f"    server_name {host};",
            "    access_log /var/log/nginx/hostproxy.access.log hostproxy;",
            header,
            acme_block(),
        ]
        if plan["mode"] == "proxy":
            out += proxy_location(plan)
        else:
            out += [
                "    location / {",
                # $request_uri 带上访客原始路径和查询串
                f'        return 302 "{target}$request_uri";',
                "    }",
            ]
        out.append("}")
    return "\n".join(out) + "\n"


def cert_names(rules: list[tuple[str, str, int]]) -> list[tuple[str, str]]:
    """(证书目录名, 来源) 对照表, 含兜底块用的 _default。

    制表符分隔输出, 让 ssl.sh 直接读, 不在 bash 里重实现一遍命名规则。
    兜底块的来源是 "-", 它不对应任何 server_name。
    """
    return [(DEFAULT_CERT, "-")] + [(cert_name(host), host) for host, _, _ in rules]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config", nargs="?", type=Path, default=Path(__file__).parent / "routes.conf")
    ap.add_argument("-o", "--output", type=Path, default=Path(__file__).parent / "build/hostproxy.conf")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="HTTP 监听端口, 默认 80")
    ap.add_argument("--https-port", type=int, default=DEFAULT_HTTPS_PORT, help="HTTPS 监听端口, 默认 443")
    ap.add_argument("--certs-dir", default=DEFAULT_CERTS_DIR, help=f"证书根目录, 默认 {DEFAULT_CERTS_DIR}")
    ap.add_argument("--no-https", action="store_true", help="不渲染 443/TLS, 只留 HTTP")
    ap.add_argument("--stdout", action="store_true", help="只打印到标准输出, 不写文件")
    ap.add_argument("--print-version", action="store_true", help="只输出配置指纹, 供部署脚本比对")
    ap.add_argument("--print-cert-names", action="store_true",
                    help="只输出需要准备证书的目录名(每行一个), 供 ssl.sh 消费")
    ap.add_argument("--print-modes", action="store_true",
                    help="只输出每条规则的来源/模式/上游(TAB 分隔), 供部署脚本标注自检结果")
    ap.add_argument("--print-defaults", action="store_true",
                    help="只输出默认参数(KEY=VALUE), 供 shell 脚本 source, 避免常量两处定义")
    ns = ap.parse_args(argv)

    if ns.print_defaults:
        print(f"CERTS_DIR_DEFAULT={DEFAULT_CERTS_DIR}")
        print(f"ACME_ROOT_DEFAULT={ACME_ROOT}")
        print(f"HTTP_PORT_DEFAULT={DEFAULT_PORT}")
        print(f"HTTPS_PORT_DEFAULT={DEFAULT_HTTPS_PORT}")
        return 0

    if not 1 <= ns.port <= 65535:
        print(f"HTTP 端口超出范围: {ns.port}", file=sys.stderr)
        return 2
    if not 1 <= ns.https_port <= 65535:
        print(f"HTTPS 端口超出范围: {ns.https_port}", file=sys.stderr)
        return 2
    if not ns.no_https and ns.port == ns.https_port:
        print(f"HTTP 和 HTTPS 端口不能相同: {ns.port}", file=sys.stderr)
        return 2
    if not PurePosixPath(ns.certs_dir).is_absolute():
        print(f"证书目录必须是绝对路径: {ns.certs_dir}", file=sys.stderr)
        return 2
    if not ns.config.is_file():
        print(f"配置文件不存在: {ns.config}", file=sys.stderr)
        return 2

    opts = {
        "port": ns.port,
        "https": not ns.no_https,
        "https_port": ns.https_port,
        "certs_dir": ns.certs_dir.rstrip("/"),
    }
    ver = version_of(ns.config, opts)
    if ns.print_version:
        print(ver)
        return 0
    try:
        rules = parse(ns.config)
    except ConfigError as e:
        print(f"{ns.config}: {e}", file=sys.stderr)
        return 2
    if ns.print_cert_names:
        for name, src in cert_names(rules):
            print(f"{name}\t{src}")
        return 0

    # 只有真正渲染时才做 DNS 判定: --print-version / --print-cert-names 被 ssl.sh 和
    # start.sh 调用, 那两条路径必须离线可用、结果稳定。
    try:
        plans = classify(rules, opts)
    except ConfigError as e:
        print(f"{ns.config}: {e}", file=sys.stderr)
        return 2
    if ns.print_modes:
        for p in plans:
            print(f"{p['host']}\t{p['mode']}\t{(p['upstream'] or p['target']) + (p['prefix'] if p['upstream'] else '')}")
        return 0

    text = render(plans, opts, ver)
    if ns.stdout:
        sys.stdout.write(text)
    else:
        ns.output.parent.mkdir(parents=True, exist_ok=True)
        ns.output.write_text(text, encoding="utf-8")
    proxy = [p for p in plans if p["mode"] == "proxy"]
    # --stdout 时配置本身占了标准输出, 摘要只能走 stderr, 免得污染管道里的 nginx 配置
    sink = sys.stderr if ns.stdout else sys.stdout
    print(f"{ns.config} -> {ns.output if not ns.stdout else '标准输出'} "
          f"({len(plans)} 条规则: {len(proxy)} 转发 / {len(plans) - len(proxy)} 跳转, HTTP {opts['port']}"
          + (f" + HTTPS {opts['https_port']})" if opts["https"] else ")"), file=sink)
    for p in plans:
        if p["mode"] == "proxy":
            print(f"  {p['host']} 转发← {p['upstream']}{p['prefix']} ({p['why']})", file=sink)
        else:
            print(f"  {p['host']} 跳转→ {p['target']}", file=sink)
    if proxy:
        # 这是安全边界的变化, 不能静默: 原来访客得自己能连上那个端口才用得了, 现在伪造 Host 就能借 80/443 打进去
        print("提醒: 以上转发规则使目标端口经由 80/443 对外可达(仅监听 loopback 的服务也算), "
              "确认这些服务允许被公网访问", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
