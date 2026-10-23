# Antseed Gateway v2

把 Antseed P2P 网络包成一个 OpenAI / Anthropic 兼容的 HTTP 代理:探活、回退、拉黑、流式转发、免费模型过滤都在这一层做。

```
客户端(Hermes/OpenAI SDK/curl)
        │  http://<host>:8377/v1
        ▼
  antseed-gateway(本仓库,Python 标准库)
        │  http://127.0.0.1:8378/v1
        ▼
  antseed buyer(P2P 客户端,官方 CLI)
```

## 安装

```bash
# 有终端就进菜单:安装/升级/卸载/更新官方 CLI/状态/日志/改配置
bash install.sh

# 一条命令安装(会问都不问,key 不给就自动生成;非交互/CI 用这个)
apikey='your-key' bash install.sh install

# 先看它要干什么
bash install.sh --dry-run

# 从 URL 装
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)
```

要求:Linux + systemd(root)。支持 Debian/Ubuntu、RHEL/Alma/Rocky/Fedora、Arch;Alpine 会被明确拒绝(官方 Node 24 要 glibc)。

装完会打印 `base_url` / `api_key`,并做一次自检(`/health` + `/v1/models`)。

## 客户端配置

OpenAI 兼容(Hermes、openai-python、LobeChat、OneAPI 等):

```yaml
base_url: http://<host>:8377/v1
api_key:  sk-antseed-xxxx
model:    auto              # auto / antseed / 具体模型名
```

Anthropic 兼容(Claude Code 类客户端):

```
ANTHROPIC_BASE_URL=http://<host>:8377
ANTHROPIC_API_KEY=sk-antseed-xxxx
ANTHROPIC_MODEL=auto
```

`auto`(或留空)走网关自己挑的最佳模型,响应头 `X-Antseed-Model` 告诉你实际用了谁。

## 接口

| 路径 | 说明 |
| --- | --- |
| `POST /v1/chat/completions` | OpenAI 对话,支持 `stream: true` |
| `POST /v1/messages` | Anthropic 消息,支持流式 |
| `GET /v1/models` | 当前可路由模型(免费过滤已生效,`auto`/`antseed` 在最前) |
| `GET /health` | 免鉴权存活探针,只报 ok/healthy/计数,不泄漏模型与身份 |
| `GET /v1/health/detail` | 需鉴权:每个模型延迟、失败次数、黑名单、请求统计 |

响应头:`X-Antseed-Model`(实际模型)、`X-Antseed-Attempt`(第几次尝试)、`X-Antseed-Fallback`(是否回退过)。

`/v1/models` 里每个模型带 `x_*` 标注(不影响 OpenAI 客户端解析):

| 字段 | 含义 |
| --- | --- |
| `x_healthy` | 最近一次探活通过且未在冷却 |
| `x_latency_s` | EWMA 延迟 |
| `x_routes_to` | `auto` 当前落在哪个模型 |
| `x_cooldown_for_s` | 还在冷却时的剩余秒数 |
| `x_last_error` | 上次失败原因(含 402 是额度还是押金) |
| `x_free_peers` | **`$0 peer / 全部 peer`**,例如 `1/22` = 22 个对端里只有 1 个免费 |
| `x_needs_deposit` | 真实请求撞到过 `insufficient_deposits`,这个模型大概率要充押金 |

`x_free_peers` 是判断"名义免费 ≠ 这次能免费"的唯一依据:过滤规则是"存在 `$0` peer 就算免费",
但 buyer 在全部 peer 里挑,`1/22` 的模型很容易被派到收费 peer。

## 配置

全部在 `/etc/antseed/gateway.env`(0600),改完 `systemctl restart antseed-gateway`。

**重装是幂等的**:已经装过再跑 `bash install.sh` 时,只会更新你**显式传入**的项(`apikey=`/`--key=`、`FREE_ONLY=`、`--port=`、`GATEWAY_BIND=`),其余行(包括你手调的超时、拉黑时长)原样保留,节点身份也复用。要换身份才用 `--force-rotate`。

### 路由

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `UPSTREAM` | `http://127.0.0.1:8378` | buyer 地址 |
| `FREE_ONLY` | `1` | 只路由 `$0` 报价的 text 模型;点名付费模型直接 400 |
| `FALLBACK_ORDER` | `deepseek-v4-flash,glm-5.3-flash,openai-gpt-oss-120b` | 同延迟档下的优先级 |
| `AUTO_FALLBACK` | `1` | 失败自动换下一个候选 |
| `FALLBACK_NAMED` | `0` | 点名具体模型失败后是否换别的模型(0 = 照实报错,与 v1 一致) |
| `SOFT_COOLDOWN` | `180` | 402/429 这类"换 peer 也许就好"的失败冷却秒数 |
| `DEPOSIT_COOLDOWN` | `60` | 402 里"押金不足"(`insufficient_deposits`)的冷却秒数,比上面更短:充值或换个 `$0` peer 立刻可用 |
| `MAX_ATTEMPTS` | `3` | 单请求最多试几个候选 |

### 探活与拉黑

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PROBE_INTERVAL` | `300` | 后台探活间隔(秒),`0` 关闭 |
| `PROBE_TIMEOUT` | `45` | 单次探测超时 |
| `PROBE_WORKERS` | `4` | 并发探测数 |
| `FAIL_THRESHOLD` | `2` | 连续失败几次拉黑 |
| `BLACKLIST_SECONDS` | `900` | 拉黑时长,期间不再作为候选 |
| `HEALTHY_TTL` | `PROBE_INTERVAL*3` | 健康状态过期时间 |

候选排序:健康 → 延迟(EWMA)→ `FALLBACK_ORDER` → 名字。

### 超时与限额

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `STREAM_IDLE_TIMEOUT` | `90` | 流式块之间最长空闲,超时断流并计数 |
| `NONSTREAM_TIMEOUT` | `300` | 非流式整请求超时 |
| `CLIENT_TIMEOUT` | `300` | 单连接总时长上限 |
| `MAX_CONCURRENCY` | `64` | 同时在处理的请求数,超出 503 |
| `MAX_BODY_MB` | `64` | 请求体上限,超出 413 |

### 402 换身份

```ini
AUTO_ROTATE=0        # 默认关闭
```

`402` 有两种,处理不同:

| 402 类型 | 判定 | 处理 |
| --- | --- | --- |
| 节点免费额度用尽 | body 无 `insufficient_deposits` | 踢出候选并回退;全都 402 时 `503 + Retry-After` |
| **押金不足**(`insufficient_deposits` / `out of AntSeed credits`) | 对端收费、本机 `antseed buyer status` 押金为 0 | `DEPOSIT_COOLDOWN`(60s)短冷却 + `/v1/models` 标 `x_needs_deposit` + 回 **402 带可操作文案**(不是 `503 no healthy model`) |

押金不足回的是 **`400` + `invalid_request_error` + `code: model_requires_deposit`**,不是 402:
DSH 这类客户端会 `status === 402` 直接判成 QUOTA 并显示"当前请求的额度已用尽",
还会用正则 `insufficient[_-](quota|balance|credits)` 二次判定 —— 所以状态码、`type`、`code`
三处都不能带配额语义。想改回去用 `DEPOSIT_STATUS=402`,但那等于接受客户端那句误导文案。

第二类**不是**"模型坏了",也不是今天的用量用完了。要让某个模型真正可用,只有两条路:
`antseed buyer deposit <金额>` 充值,或改用 `$0` peer 多的免费模型(`auto` 默认就落在那上面)。

`AUTO_ROTATE=1` 会额外触发 `antseed-rotate.service`(oneshot):换节点身份 → 重启 buyer → 等就绪 → 重试同一模型一次。

**为什么默认关**:换身份重刷免费额度会踩平台限流/风控,轻则 buyer 长时间 429,重则身份被拉黑。这条是产品策略问题,不是技术问题 —— 想开就开,但知道代价。

## 运维

```bash
systemctl status antseed-gateway antseed-buyer
journalctl -u antseed-gateway -f
journalctl -u antseed-buyer -f

curl -s http://127.0.0.1:8377/health | python3 -m json.tool
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8377/v1/health/detail | python3 -m json.tool
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8377/v1/models | python3 -m json.tool
```

换 key / 改端口 / 调超时:改 `/etc/antseed/gateway.env` 后 `systemctl restart antseed-gateway`,不用重装。

换 API key(会提示同步客户端):

```bash
bash install.sh --key=sk-antseed-新key
```

换节点身份:

```bash
systemctl start antseed-rotate.service      # 手动轮换,日志 /var/log/antseed-rotate.log
bash install.sh --force-rotate             # 或重装时强制换(等价 FORCE_ROTATE=1)
```

## 升级 / 卸载

```bash
bash install.sh upgrade          # 换网关程序 + unit,保留配置与身份
bash install.sh uninstall        # 停服务删程序,保留 /etc/antseed 与节点身份
bash install.sh uninstall --purge  # 连配置和节点身份一起删
```

## 改这个项目

```bash
vim gateway.py                   # 改网关
python3 tests/test_gateway.py    # 59 项行为测试:假上游 + 真网关进程,不需要真 buyer
bash tools/build-install.sh      # 重新生成 install.sh(会校验内嵌副本与源文件逐字节一致)
bash install.sh --dry-run        # 看安装流程
```

`install.sh` 是构建产物,别手改 —— 下次 build 就冲掉了。安装器里内嵌的 `gateway.py` 必须是**同一份代码**,否则"本地测的是 A、装上去的是 B",这正是这类自包含安装器最容易翻车的地方。

### 仓库结构

| 路径 | 说明 |
| --- | --- |
| `gateway.py` | 网关程序(纯标准库 Python 3.7+) |
| `install.sh.tpl` → `install.sh` | 安装器本体与它的构建产物(自包含,内嵌 `gateway.py`) |
| `tools/build-install.sh` | 生成 `install.sh` 并做正反向字节校验 |
| `tests/` | 行为测试(假上游 + 真网关进程,不碰线上) |

## 排错

| 现象 | 排查 |
| --- | --- |
| `/v1/models` 只有 `auto`/`antseed` | buyer 没就绪或全网无免费节点:`curl 127.0.0.1:8378/v1/models`、`journalctl -u antseed-buyer -n 50` |
| 全部 503 | `/v1/health/detail` 看是不是全被拉黑;等 `BLACKLIST_SECONDS` 或 `systemctl restart antseed-gateway` 清空内存态 |
| 一直 401 | key 在 `gateway.env` 里被加了引号/空格;客户端发的是 `Authorization: Bearer` 或 `x-api-key` |
| 流式像卡住 | `STREAM_IDLE_TIMEOUT` 太小,或客户端/Nginx 缓冲:`proxy_buffering off;` |
| buyer 反复重启 | 看 `journalctl -u antseed-buyer`;OOM 就降 `MAX_CONCURRENCY`,或换大内存机型 |
| 外网连不上 | `GATEWAY_BIND` 是不是还是 `127.0.0.1`;云厂商安全组是否放行端口 |

## 致谢 (Acknowledgements)

本项目站在这些公开项目的肩膀上：

| 项目 | 用途 |
|---|---|
| [Antseed](https://antseed.com) | 上游本身——AI 推理的开放市场，本项目的模型能力全部来自它 |
| [@antseed/cli](https://www.npmjs.com/package/@antseed/cli) | 官方 P2P 客户端（`antseed buyer`），网关把请求转发到它的本地 8378 端口 |
| [Node.js](https://nodejs.org/) | 官方 CLI 的运行时，`install.sh` 装一份内置版，不动系统 Node |

网关本体零第三方依赖，只用 Python 标准库。

## 免责声明 (Disclaimer)

本项目仅供学习、研究与个人技术实验使用，请勿用于任何可能违反第三方服务条款（ToS）或适用的法律法规的场景。

- 本项目**非官方**，与 Antseed 及其运营方无任何关联、无背书（not affiliated with or endorsed by）。仓库里不包含、也不分发上游任何代码——`@antseed/cli` 是官方独立发布的 npm 包（Proprietary），由安装脚本从 npm 现取。
- 免费模型与免费额度的可用性完全取决于上游策略，随时可能变化或失效（下架、加闸、限流、改协议、风控封号均有可能），本项目不对其持续性、稳定性作任何担保。**免费通道随时会断，这是免费层的本质，不是 bug。**
- 需要稳定通道，请直接使用[官方 CLI](https://www.npmjs.com/package/@antseed/cli) 与官方账户额度。
- 网关本身不收集、不上报任何用户数据，也不把请求内容落盘；运行日志只落在本机 systemd journal。你的 API key 与节点身份只存在于本机 `/etc/antseed/`。
- 通过本项目访问上游所产生的账号封禁、额度清零、费用、法律或经济风险，均由使用者自行承担；使用本项目即视为你理解并接受这一点。
- 软件本体按 MIT 协议 "AS IS" 提供，不带任何担保（见 [LICENSE](./LICENSE)）。

## License

[MIT](./LICENSE) © 2026 [pingmike2](https://github.com/pingmike2)
