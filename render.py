#!/usr/bin/env python3
"""把 routes.conf 渲染成 nginx server 块。

用法: python3 render.py [routes.conf] [-o 输出文件] [--port 80] [--https-port 443]
                        [--stdout] [--print-version] [--print-cert-names]
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import re
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
    比 / 长, 所以这里的 token 不会被下面那条 return 302 抢走。^~ 是防以后加正则 location。
    """
    return "\n".join([
        "    location ^~ /.well-known/acme-challenge/ {",
        f"        root {ACME_ROOT};",
        "        default_type text/plain;",
        "        try_files $uri =404;",
        "    }",
    ])


def render(rules: list[tuple[str, str, int]], opts: dict, ver: str) -> str:
    port, https_port, certs_dir = opts["port"], opts["https_port"], opts["certs_dir"]
    header = f'    add_header X-Rules-Version "{ver}" always;'
    out: list[str] = [
        f"# 由 render.py 从 routes.conf 自动生成, 不要手工编辑。版本 {ver}",
        f"# hostproxy-port: {port}",
        f"# hostproxy-https-port: {https_port if opts['https'] else 'off'}",
        f"# hostproxy-certs-dir: {certs_dir}",
        "log_format hostproxy '$time_iso8601 host=\"$host\" port=$server_port req=\"$request\" -> $status';",
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

    for host, target, _ in rules:
        out += [
            "",
            f"# {host}  ->  {target}",
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
            "    location / {",
            # $request_uri 带上访客原始路径和查询串
            f'        return 302 "{target}$request_uri";',
            "    }",
            "}",
        ]
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

    text = render(rules, opts, ver)
    if ns.stdout:
        sys.stdout.write(text)
    else:
        ns.output.parent.mkdir(parents=True, exist_ok=True)
        ns.output.write_text(text, encoding="utf-8")
        print(f"{ns.config} -> {ns.output} ({len(rules)} 条规则, HTTP {opts['port']}"
              + (f" + HTTPS {opts['https_port']})" if opts["https"] else ")"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
