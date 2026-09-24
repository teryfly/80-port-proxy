# 80 端口域名跳转代理

监听本机 80 和 443 端口，读取访客请求里的 `Host` 头（也就是"他用哪个域名/IP 访问的"），
按配置文件里的映射返回 302 跳转；`Host` 匹配不到任何一条规则时返回 **400**。
访客用 `http://` 还是 `https://` 访问都一样，**不做强制跳转**，两条协议各答各的。

转发工作本身完全交给 nginx，本仓库只包含一个配置渲染器和几个运维脚本，
没有请求处理代码，因此没有连接数、超时、chunked、keep-alive 这类需要自己维护的东西。

```
访客 ──HTTP:80──┐
                ├─> nginx ──┬── Host 命中 routes.conf ──> 302 Location: 目标地址 + 原始路径/查询串
访客 ─HTTPS:443─┘           └── Host 未命中           ──> 400 Bad Request
```

443 这一路只在握手上多一层 TLS，转发规则和 80 完全共用一份 `routes.conf`；
证书怎么来的见 [HTTPS 与证书](#https-与证书)。

## 文件

| 文件 | 作用 |
|---|---|
| `routes.conf` | **唯一需要编辑的**：来源 → 目标 映射表 |
| `render.py` | 校验 `routes.conf` 并渲染成 nginx `server` 块（纯标准库） |
| `install.sh` | 首次安装：查依赖 → 装 nginx → 应用配置 → 询问是否开机自启 |
| `deploy.sh` | 把最新 `routes.conf` 应用到 nginx，校验失败自动回滚，生效后自检 |
| `ssl.sh` | 证书：补齐自签证书（`deploy.sh` 自动调）、换 Let's Encrypt 受信证书、看到期 |
| `start.sh` | 日常启停与状态查看（`start` / `reload` / `restart` / `stop` / `status`） |
| `build/` | 渲染产物和上一次配置的备份，可随时删除 |

## 环境要求

- Linux + systemd（脚本用 `systemctl` 管理服务）
- nginx（`install.sh` 会自动 apt 安装），且编译带 `http_ssl_module`（发行版默认的都有）
- python3（仅标准库）、curl、awk、openssl
- root 或免密 sudo
- 想签 Let's Encrypt 受信证书再额外要 certbot（本项目不自动装）

## 快速开始

```bash
# 1. 填自己的规则
vim routes.conf

# 2. 安装并生效（会问你是否开机自启）
./install.sh

# 3. 验证：改 Host 头模拟不同域名的访客
curl -I -H 'Host: www.example-a.com' http://<服务器IP>/
curl -I -H 'Host: not-configured.example' http://<服务器IP>/   # 期望 400

# 4. HTTPS 同一套规则，证书是现签的所以浏览器不认，探测要加 -k
curl -kI -H 'Host: www.example-a.com' https://<服务器IP>/
curl -kI -H 'Host: not-configured.example' https://<服务器IP>/   # 期望 400
```

之后每次改完 `routes.conf`，执行 `./deploy.sh`（或 `./start.sh reload`）即可热生效，不断连接。

## 配置 routes.conf

每行一条规则，两列，空格分隔，`#` 后为注释：

```conf
#  来源(访客用的 Host)          目标跳转地址
   www.foo.com                  http://10.0.0.5:8080
   api.foo.com                  http://10.0.0.5:9000/v2
  *.img.foo.com                 http://10.0.0.6:8000/assets
   203.0.2.5                    http://10.0.0.7:3000
```

### 来源支持三种写法

| 写法 | 匹配范围 |
|---|---|
| `www.foo.com` | 精确域名 |
| `*.foo.com` | 以 `.foo.com` 结尾的任意名字，**含多级**（`a.foo.com`、`a.b.foo.com`），但**不含 `foo.com` 本身**，要覆盖裸域就再加一行 |
| `203.0.2.5` | 访客直接用 IP 访问时，`Host` 头就是这个 IP |

优先级由 nginx 决定：**精确名 > 通配符 > 兜底 400**。两者同时配置时精确名赢，可放心叠加。
`Host` 里带端口（如 `Host: www.foo.com:80`）nginx 会先剥掉端口再匹配，不影响。

`*.img.foo.com` 匹配的是访客 `Host` 头里的**真实子域名**（`a.img.foo.com`、`a.b.img.foo.com` 都算），
所以配套要做两件事：DNS 上加一条 `*.img.foo.com` 泛解析指到本机，以及别把 `*.img.foo.com` 本身
当网址输进浏览器——那样发不出这个 `Host`，规则永远不命中。要覆盖 `foo.com` 裸域就单独再写一行。

### 目标地址

必须是完整的 `http(s)://主机[:端口][/路径]`。访客原始的路径和查询串会自动拼在目标后面，
所以目标里不用写，写了路径就等于**加前缀**：

| 访客请求 | 跳转到 |
|---|---|
| `http://www.foo.com/list?id=3` | `http://10.0.0.5:8080/list?id=3` |
| `http://a.img.foo.com/img/a.png`（规则目标写了 `/assets`） | `http://10.0.0.6:8000/assets/img/a.png` |

目标结尾多余的 `/` 会被去掉，避免出现 `//`。

### 配置错误会被挡住

`render.py` 在动 nginx 之前校验，出错就退出并且**完全不碰线上配置**（实测：报错退出后旧规则照常服务）：

- 目标缺 `http://`/`https://` 前缀、缺主机名、端口非数字
- 目标含 `$ ; " ' \` 等会破坏 nginx 配置或注入变量的字符
- 来源写法不合法、通配符不在最前、来源重复
- 一行不是两列、一条规则都没有

## HTTPS 与证书

443 用的证书放在 `/etc/nginx/certs/hostproxy/<证书目录>/{fullchain.pem,privkey.pem}`。
证书目录名由来源推导（`*.` 换成 `_w.`，兜底 400 那块固定叫 `_default`），对照表用
`python3 render.py --print-cert-names` 打印（TAB 分隔）。

开源版 nginx 一个 `server` 块只能挂一张证书，而本项目本来就是一条规则一个块，
所以**一条规则一张证书**，握手时由访客的 SNI 决定给哪张。实测：

```bash
$ echo | openssl s_client -connect <服务器IP>:443 -servername a.example-b.com 2>/dev/null | grep ^subject
subject=CN = *.example-b.com          # 通配符规则命中，a.b.example-b.com 同理
```

`./deploy.sh` 会在 `nginx -t` 之前先跑 `./ssl.sh ensure`：

- 哪个来源缺证书就**现签一张自签证书**（RSA 2048、825 天、SAN 写着这个来源），
  所以 `nginx -t` 不会因为证书不齐而把一份好配置回滚掉。
- 已经能用（能解析、私钥配得上、没临近过期）的一律不动，**包括你自己放的证书**。
- 你手放的证书如果 SAN 里没有对应来源，只告警不覆盖——名字不匹配是浏览器的事，不替你决定。

自签证书功能完全正常，但浏览器一定告警（信任是签不出来的）。要受信证书就换成 Let's Encrypt：

```bash
sudo apt-get install -y certbot        # 本项目不自动装
sudo ./ssl.sh le www.foo.com           # 只处理精确域名来源；--all 或裸 ./ssl.sh le 处理全部
sudo ./ssl.sh status                   # 看每个来源用的哪张、还剩几天
```

`le` 走 webroot HTTP-01：配置里每个 `server` 都留了 `/.well-known/acme-challenge/`，
指向 `/var/www/letsencrypt`，它比 `location /` 长所以不会被 302 抢走，跳转照常。
所以签发前提和访客访问前提一样：**该域名的 DNS 已指到本机、安全组放行 TCP 80**。
签完把证书目录里两个文件换成指向 `/etc/letsencrypt/live/<域名>/` 的软链，
续期时 certbot 原地更新，`nginx` 只需要 reload（nginx 1.x 不会热加载证书）。

两个签不了受信证书的情况，`le` 会直接跳过并说明原因：

- `*.foo.com` 这类通配符来源：泛域名证书只能 DNS-01（要 DNS 服务商凭据），webroot 办不到。
  自签证书本身是能带 `DNS:*.foo.com` 这个 SAN 的，功能正常，只是不受信。
- 裸 IP 来源：客户端访问 IP 时不发 SNI，握手一定落在兜底块上（拿到 `_default` 那张证书）。
  请求读完 `Host` 头之后仍然会按你的规则跳转，所以 `https://<IP>/` 能得到正确的 302，
  只是证书名称对不上、浏览器会告警。

想全套用自己的证书（公司内部 CA、已有的付费证书），把对应目录里那两个文件换成你的即可，
`ensure` 认得出来不会覆盖；目录和权限约定：私钥 `0600`，其余 `0755`/`0644`，nginx 主进程以 root 读。

只想留 HTTP：`HTTPS=off ./deploy.sh`（一条 TLS 指令都不渲染，443 随之释放）。
装定时器每天续期并 reload：`sudo ./ssl.sh install-renew-timer`（可选，只有签了 LE 证书才需要）。

## 日常操作

```bash
./start.sh              # 拉起服务并应用最新配置（幂等）
./start.sh reload       # 同上，改完配置用这个
./start.sh restart      # 先校验写盘再完整重启，会短暂中断
./start.sh stop         # 停止 nginx（注意：本机其它 nginx 站点会一起下线）
./start.sh status       # 服务状态 / 两个端口监听 / 规则数 / 生效版本 / 证书 / 自检 / 最近日志
./deploy.sh             # 只应用配置（start.sh reload 的底层就是它）
./ssl.sh status         # 每个来源用的哪张证书、受信与否、还剩几天
./ssl.sh ensure         # 手工补证书（平时不用，deploy.sh 会自动调）
PORT=8080 ./deploy.sh   # 换端口生效（仍要 sudo，因为要写 /etc/nginx）；跑完 ./deploy.sh 回到 80
PORT=8080 HTTPSPORT=8443 ./deploy.sh          # HTTP/HTTPS 两个端口一起换着试跑
HTTPS=off ./deploy.sh                         # 只要 HTTP，一条 TLS 指令都不渲染
python3 render.py --stdout --port 8080        # 不需要 root，只把渲染结果打出来看，不动线上
python3 render.py --stdout --https-port 8443  # 同上，看 443 那部分长什么样
```

`install.sh --enable-boot` / `--no-enable-boot` 可跳过询问直接设定开机自启（非交互环境不会追问）。

## 怎么确认真的生效了

`nginx -t` 通过、`reload` 返回 0 都**不等于**新配置已经在应答：reload 是异步的，
旧 worker 还会用上一份配置继续处理几百毫秒。所以每条响应都带了配置指纹头：

```bash
$ curl -sI -H 'Host: probe-missing.invalid' http://127.0.0.1/ | grep X-Rules-Version
X-Rules-Version: 846685ba4895      # routes.conf 内容 + 渲染参数(端口/证书目录)的 sha256 前 12 位
```

探测请用**兜底 Host**（随便一个没配置的域名）而不是你的第一条规则：第一条可能是 `*.foo.com`
或裸 IP，那种字面值永远不会成为请求里的 `Host`，探到的其实是兜底块的响应。

它和 `./start.sh status` 里的"磁盘版本"一致，才说明当前跑的就是你刚保存的规则；
不一致就是没应用，跑 `./deploy.sh`。`deploy.sh` 自己也在轮询这个头，**HTTP 和 HTTPS 两个端口
都要对上**才打印自检结果。只改端口（比如 `HTTPSPORT=8443`）指纹也会变，因为线上配置确实变了。

## 日志

```bash
sudo tail -f /var/log/nginx/hostproxy.access.log
# 2026-09-24T12:35:39+08:00 host="probe-missing.invalid" port=443 req="GET / HTTP/1.1" -> 400
```

每个请求一行，`host` 就是被判定/被拒的来源，`port` 区分这个访客走的是 HTTP(80) 还是 HTTPS(443)，
排查"为什么这个访客没跳转"直接看这两列。

## 想改成反向代理（地址栏不变）

现在跳转后浏览器地址栏会显示目标地址，这是设计如此（302）。
若要让访客始终看到原域名，把 `render.py` 里生成规则块的那行 `return 302` 换成 `proxy_pass`：

```python
# 原来
f'        return 302 "{target}$request_uri";',
# 改成（target 是写死的字面量, 不需要 resolver 指令）
f'        proxy_pass {target};',
'        proxy_set_header Host $host;',
'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
```

兜底 400 那块和配置指纹头都不用动。改成代理后要额外处理：Cookie 域、目标站点返回的
绝对地址重写、WebSocket 升级，以及"目标必须本机可连通"这条新约束（302 是由访客浏览器去连目标，
本机连不通也无所谓）。改动量比现在大不少，确认需要再动。

## 注意事项

- **HTTPS 只覆盖"访客到本机"这一段**。302 是让访客的浏览器再去连目标，本机根本不碰目标的服务端，
  所以跳转目标写成 `http://` 时访客最终仍落在非加密站点上。目标支持 HTTPS 就尽量写 `https://`，
  这和自己监听 443 是两件事。
- **默认证书是自签的**，功能正常但浏览器一定告警；受信证书见 [HTTPS 与证书](#https-与证书)。
- **域名解析在访客侧**。本程序只负责收到请求后按 `Host` 判断，域名 DNS 要自己指到这台机器。
- **云服务器还要放行安全组**：入方向 TCP 80 **和 TCP 443**。本机若开了 ufw：
  `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`。
- **安装会摘掉 nginx 自带站点**：`/etc/nginx/sites-enabled/default` 的软链被移除（文件本身保留），
  因为它同样声明 `default_server`，会和兜底 400 那块冲突。
- 兜底 400 的响应体是 `text/plain`，会写明被拒的 Host；不带 `Host` 头的 HTTP/1.0 请求同样落在这里。

## 卸载

```bash
sudo rm -f /etc/nginx/sites-enabled/hostproxy.conf /etc/nginx/sites-available/hostproxy.conf
sudo rm -rf /etc/nginx/certs/hostproxy /var/www/letsencrypt       # 证书和挑战目录(自签的可随时重签)
sudo systemctl disable --now hostproxy-renew.timer 2>/dev/null    # 只有装过续期定时器才需要
sudo rm -f /etc/systemd/system/hostproxy-renew.{service,timer} && sudo systemctl daemon-reload
sudo ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl disable --now nginx    # 顺带停掉并取消自启
```

证书目录里如果是你自己放的付费/内部 CA 证书，删之前先备份。`/etc/letsencrypt` 归 certbot 管，
要清理用 `sudo certbot delete --cert-name <域名>`。
