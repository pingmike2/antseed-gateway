# v2.0.10:413/400 回绝时没关连接,客户端看到的是"连接被重置"而不是错误文案

## 现象

超限请求体(默认 `MAX_BODY_MB=64`)本该拿到 `413`,实际却是:

```
curl: (56) Send failure: Connection was aborted
# 或 Python http.client: ConnectionAbortedError(10053) / RemoteDisconnected
```

`Content-Length` 写坏时同理:400 的文案偶尔能收到,更多时候是断连;同一个 keep-alive 连接
上还会接着出现一个莫名其妙的 `400`,因为残留的 body 被当成下一个请求行解析。

## 根因

`do_POST()` 里三条"请求体还没读完就回绝"的路径(413 超限、400 坏长度、以及 404/401)只
`_err()` 了一下,**没有 `Connection: close`,也没有读掉残留 body**。`BaseHTTPRequestHandler`
在 HTTP/1.1 下默认 keep-alive,于是:

1. 我们回 413 后连接保持打开,客户端还在发 2MB;
2. 网关接着把这段 body 当请求行读,读到超长行 / 非法字节;
3. 客户端先撞上 `RST`,才轮到我们的错误文案 —— 所以它看见的永远是断连。

v2.0.0 的验证记录里写过"2MB body → 413",但那只是看了状态码,没看连接语义,所以没暴露。

## 修法:回绝前先把残留 body 读掉(有上限),再显式关连接

```python
def _reject_body(self, status, msg):
    self._discard_body()                 # 最多 DRAIN_BODY_MB(默认 8MB),带 1s 超时
    self.close_connection = True
    return self._err(status, msg, extra={"Connection": "close"})
```

- 新增 `DRAIN_BODY_MB`(默认 8):读掉残留是为了让对面能收完响应;设上限是为了不被超大 body 拖住
- 413 / 400(坏 `Content-Length`)/ 上部 `/v1` 之外的 404 / 未通过鉴权的 401 四条路径统一走它
- `gateway.env` 里同步写了 `DRAIN_BODY_MB=8` 与注释

## 验证

[`tests/test_gateway.py`](tests/test_gateway.py)(59 项,含假上游 + 真网关进程):修前 3 项失败,修后 0 失败。

| 用例 | 修前 | 修后 |
| --- | --- | --- |
| 2MB body(上限 1MB) | `ConnectionAbortedError(10053)` | `413` |
| 413 响应头 | 无 | `Connection: close` |
| `Content-Length: abc` | `400`,无 `Connection` 头 | `400` + `Connection: close` |

# v2.0.9:客户端给的 `openai/gpt-6-luna` 不再被当成"另一个模型"

## 现象

v2.0.8 之后,`gpt-6-luna` / `gpt6luna` / `openai-gpt-6-luna` 都能正确回押金说明,但 DSH 里选的
那一串是 **`openai/gpt-6-luna`**,网关回的是另一句:

```
model 'openai/gpt-6-luna' not in free catalog (upstream has no such model: removed or renamed)
```

## 根因

`canonical_model()` 只查别名表(`alias_map()`),而别名表里没有"provider 前缀"这层写法。
DSH 界面上把模型挂在 provider 分组下,发出去的 model 字符串就带 `openai/` 前缀。

## 修法:查不到时逐层剥前缀,但只在"剥完能查到"时剥

```python
if "/" in name:
    parts = name.split("/")
    for i in range(1, len(parts)):
        tail = "/".join(parts[i:])
        hit = m.get(tail) or m.get(tail.lower())
        if hit: return hit
if ":" in name:            # openai:gpt-6-luna 老写法
    ...
```

关键约束:目录里本来就有带斜杠的 id(`inclusionai/ling-3.1-flash`)。因为先查整串、命中就返回,
所以真 id 不会被剥坏;只有整串查不到才尝试尾巴,`vendor/openai/x` 这种两层前缀也能剥。

## 验证

[`tests/test_gateway.py`](tests/test_gateway.py) 新增 5 条(19 passed, 0 failed):

| 用例 | 期望 |
| --- | --- |
| `openai/m-free` | 200,剥前缀生效 |
| `openai/m-dep` | 400 `model_requires_deposit`(不是"没这个模型") |
| `vendor/openai/m-free` | 200,两层前缀 |
| `inclusionai/m-free` | 200 且上游收到的仍是带斜杠的真 id |
| `openai:m-free` | 200,冒号写法 |

# v2.0.8:押金提示被客户端"翻译成额度用尽"的根因修复

## 现象

v2.0.7 已经把 402 的语义说明白了(`curl` 能看到"对端要押金…"),但在 **DSH 客户端**里选
`openai/gpt-6-luna`,界面依然只显示:

```
本轮运行失败  当前请求的额度已用尽
```

## 根因:客户端的错误分类器,不是"不看 body"

`@deepseek-ai/dsh-llm-deepseek` 的 `providerError()` 这样判:

```js
if (status === 401 || status === 403 || ["authentication_error","permission_error"].includes(type)) code = "AUTH";
else if (isQuotaExceededError(detail) || status === 402) code = "QUOTA";   // ← 两个陷阱
...
```

而 `isQuotaExceededError()` 用的是正则:

```js
/\binsufficient[\s_-]+(?:quota|balance|credits?)\b/i   // detail = type + code + message
```

v2.0.7 的回包**同时踩了两条**:

| v2.0.7 回包 | 命中 |
| --- | --- |
| `HTTP 402` | `status === 402` → QUOTA |
| `"type": "insufficient_quota"` | `insufficient[\s_-]+quota` → QUOTA |

于是 code=QUOTA,UI 按 `message.failure.quota` 渲染成"当前请求的额度已用尽",**我们写的 message 根本没机会显示**。

## 修法:换成客户端会照实显示 message 的状态与字段

```json
HTTP 400
{"error": {"message": "对端要押金(insufficient_deposits):…改用 auto 或其它免费模型;要用它就先 antseed buyer deposit <金额>",
           "type": "invalid_request_error",
           "code": "model_requires_deposit",
           "param": "deposits"}}
```

- `400` + `invalid_request_error` → 客户端判为 `INVALID_REQUEST`,而它的 `failureMessage()` 对
  非 AUTH/QUOTA 的 code **原样显示 message**
- 文案与 code 里**不出现** `quota` / `credits` / `out of credits` 等配额字样,避免被正则二次命中
- 新环境变量 `DEPOSIT_STATUS`(默认 `400`)可改回 `402` —— 但改回去就等于接受"客户端会说额度用尽"

## 验证:把回包喂给客户端判定器

复刻 `providerError()` + `isQuotaExceededError()` + `failureMessage()` 的脚本
([`tests/dsh_classify.mjs`](tests/dsh_classify.mjs))对同一份 body 判定:

```
旧回包(402 + insufficient_quota):  {"code":"QUOTA","shown":"当前请求的额度已用尽"}
新回包(400 + invalid_request_error): {"code":"INVALID_REQUEST","shown":"对端要押金(insufficient_deposits):…"}
```

第一条正是用户看到的原话,第二条说明修复后 message 会照实显示。

## 同时确认的事实

`gpt-6-luna` 的免费额度**确实不可用**,不是偶发:直连 buyer 连打 6 次,6 次全是
`insufficient_deposits`;目录里那唯一的 `$0` peer(`antseed-aggregator`,标签带 free)
并没有真的在服务。想用它只有 `antseed buyer deposit <金额>`。

# v2.0.7:押金不足(402 insufficient_deposits)不再谎报"额度用尽"

## 现象

点名 `gpt-6-luna`(或 `gpt-5.6-luna` 这类"便宜但只有一个 $0 peer"的模型)时,客户端弹出
"本轮运行失败,当前请求的额度已用尽" —— 明明当天一次都没用过。

## 根因:三个环节各说各话

| 环节 | 它看到的事实 |
| --- | --- |
| 上游目录 | `gpt-6-luna` 有 **22 个 peer**,其中 **1 个** `$0`(antseed-aggregator),其余收费(最低 $0.0016/M) |
| 网关 `/v1/models` | 过滤规则是"存在 $0 peer 就算免费"(与 v1 一致)→ luna **列进免费目录** |
| buyer 路由 | 在全部 22 个 peer 里按价格/信誉挑 → 可能落到**收费 peer** |
| AntSeed 账户 | `antseed buyer status` → `Deposits available 0.0 USDC` |

收费 peer + 押金 0 = HTTP 402 `insufficient_deposits`:

```json
{"error":{"type":"api_error","code":"antseed_buyer_fault",
 "message":"You are out of AntSeed credits for this request. Add funds in the AntSeed app,
            or run \"antseed buyer deposit <amount>\" from the CLI, then retry.",
 "param":"insufficient_deposits"}}
```

客户端把这句译成"额度已用尽",于是看起来像自己把免费额度花光了。**不是用量问题,是钱的问题。**

## 修法(1+2)

**1) 不再把押金不足当成"模型坏了"**

- 识别 402 body 里的 `insufficient_deposits` / `out of AntSeed credits` / `add funds`
- 冷却从 `BLACKLIST_SECONDS`(900s)改为新的 `DEPOSIT_COOLDOWN`(默认 60s)——
  充值或换个 $0 peer 立刻就能用,不该一小时不能碰
- 探活遇到押金类 402 **不再重试**(同一笔账,重试无意义)
- 请求还没发出去但模型已被判押金时,回 **402 + 解释**,而不是 `503 no healthy model available`
- 文案换成能看懂的:`对端要押金(insufficient_deposits):这个模型只挂了极少数 $0 peer,
  本次请求被派到了收费 peer,而本机 AntSeed 押金为 0。改用 auto 或其它免费模型;
  要用它就先 antseed buyer deposit <金额>`

**2) `/v1/models` 标出"名义免费 vs 实际能不能免费"**

```json
{"id": "gpt-6-luna",
 "x_free_peers": "1/22",          // 22 个 peer 里只有 1 个 $0
 "x_needs_deposit": true,          // 已经踩过 insufficient_deposits
 "x_healthy": false, "x_cooldown_for_s": 57,
 "x_last_error": "HTTP 402 对端要押金(insufficient_deposits)…"}
```

`/health` 也新增 `needs_deposit: ["gpt-6-luna"]`。

## 没动的部分

- 免费过滤规则不变(仍然是"存在 $0 peer"),所以 luna 依然在目录里、依然能 `x_healthy`
  通过探活 —— **列表归列表**
- `auto` 的候选逻辑不变,不会主动去点这类模型 —— **路由归路由**
- `FALLBACK_NAMED` 默认仍为 0:点名模型失败就照实报错,不偷偷换模型

## 顺带

- `install.sh.tpl` 的 `gateway.env` 模板新增 `DEPOSIT_COOLDOWN=60`,`install.sh status`
  的配置段会把它列出来

# v2.0.6 新增:`install.sh` 交互菜单 + 官方 CLI 更新

## 1. `bash install.sh` 不带参数 = 菜单

以前不带参数就是"直接装",装完想卸载/看状态/改配置还得翻文档。现在:

```
==================================================
   Antseed Gateway 管理菜单      安装器 v2.0.6
--------------------------------------------------
   网关 2.0.6  active    CLI 0.1.196  端口 8377
--------------------------------------------------
  1) 安装 / 重装网关        (保留已有配置与节点身份)
  2) 升级网关程序           (只换程序与 unit,不动配置)
  3) 卸载网关               (可选连配置与身份一起删)
  4) 更新官方 CLI           (检测到新版才装 @antseed/cli)
  5) 状态与自检             (/health、模型、端口)
  6) 查看日志               (最近 60 行 / 实时跟随)
  7) 修改配置               (API key、端口、FREE_ONLY…)
  0) 退出
==================================================
```

**兼容性**:只有"无参数 + 交互终端"才进菜单。`curl | bash`、`bash install.sh < /dev/null`、
管道里的 `bash install.sh` 仍然是直接安装;要强制跳过菜单用 `NO_MENU=1 bash install.sh`。

## 2. 官方 CLI 更新(第 4 项)

`/usr/bin/antseed` 是 npm 全局包 `@antseed/cli` 的符号链接(`-> ../lib/node_modules/@antseed/cli/dist/cli/index.js`),
官方没提供 `antseed update` 子命令,所以更新只能走 npm:

1. 读出已装版本:`node <antseed> --version`
2. 问 registry:`npm view @antseed/cli version`(离线/查不到就**什么都不做**)
3. 比版本(`sort -V`),**没有新版就只打印"已是最新($cur),不做任何改动"**
4. 有新版:`npm install -g @antseed/cli@<latest>`,再确认二进制还在、版本变了
5. `systemctl restart antseed-buyer` 让常驻进程用上新 CLI,并等它的 `/v1/models` 就绪
6. 打印"网关会在 60s 内自动刷新模型目录,无需重启"

退出码:`0` 已是最新或更新成功,`1` 有新版(`--check` 模式),`3` 查不到最新版本。

## 3. 新增非交互子命令

| 命令 | 作用 |
| --- | --- |
| `bash install.sh menu` | 强制进菜单(终端建议 tty) |
| `bash install.sh status` | 服务状态、端口、网关版本、配置项、`/health`、模型条目与健康数 |
| `bash install.sh logs [--follow] [--lines=N]` | 日志(默认最近 60 行) |
| `bash install.sh config` | 交互改 API key / FREE_ONLY / 监听地址 / 端口 / FALLBACK_NAMED / AUTO_ROTATE / 探活周期,改完自动重启网关 |
| `bash install.sh update-cli [--check] [--yes]` | 官方 CLI 检测/更新;`--check` 只报告,`--yes` 不确认 |

## 4. 顺手修的三处

- **`read_env` / `cli_current` / `cli_latest` / `menu_gw_version` 都加了 `|| true` 与存在性判断**:
  `set -o pipefail` + ERR 陷阱下,卸载后读不到 `gateway.py`、离线时 `npm view` 失败,
  原来会打出"中断于第 N 行 (exit 2)"。现在这些"读不到"只当"没有值"处理。
- **`status` 在网关不可达时不再半截**:配置段改成 shell 直接读 `gateway.env`,HTTP 段逐节容错,
  `/v1/models` 返回 502/401 时打印 `HTTP 502: <上游原因>`,而不是整个章节消失。
- **菜单项执行完立即退出**:原来 `menu` 分支跑完会掉进下面的安装流程,导致"改完配置又被写回默认值"。

# v2.0.5 修复:模型"变少"了 + 别名调不通

## 1. `/v1/models` 只列探活通过的模型(高)

**现象**:以前能看到 `deepseek-v4-flash` / `glm-5.3-flash` / `mimo-v2.6-flash`,现在列表只剩七八个。

**根因**:v2 把"列表"和"路由"混在一起了。`_models()` 返回的是 `H.healthy()`,也就是**探活通过的模型**;
而 v1 返回的是"上游目录里存在 $0 报价 peer 的 text 模型",完全不看健康度。于是:

- `deepseek-v4-flash`:上游有 13 个 peer、其中 2 个 $0,探活拿到 HTTP 402(当前没额度)→ 被拉黑 → 从列表消失
- `gpt-6-luna` / `mycellios-*`:402 / 429(对端并发满)→ 同样消失
- `mimo-v2.6-flash`:上游 7 个 peer,**最低报价 $0.02/$0.05,没有 $0 peer** → 这条在 v1 里也会被过滤,
  不是网关改的,是上游不再免费了

**修复**:`/v1/models` 改为列出**全部免费目录**(与 v1 同一套规则),健康度改用字段表达:

```json
{"id": "deepseek-v4-flash", "x_healthy": false, "x_cooldown_for_s": 240,
 "x_last_error": "HTTP 402: ..."}
```

`auto` 仍然只落在健康模型上(`x_routes_to` 会写出落点)。列表归列表,路由归路由。

## 2. 用别名调用被判"非免费模型"(高)

`glm-5.3-flash` 在上游目录里的 `aliases` 是 `["glm-5-3-flash", "glm-5.3-flash", "glm53flash", "z-ai-glm-5-3-flash"]`。
之前网关只认 `id`,`model: "glm-5-3-flash"` 直接被 FREE_ONLY 守卫挡回:

```
model 'glm-5-3-flash' is not a free model. use model=auto, or one of: ...
```

**修复**:新增别名索引 `_build_alias()` / `canonical_model()`,请求进来先把别名换成规范 id 再走守卫与路由
(`glm-5-3-flash` → `glm-5.3-flash`),大小写也认。拒绝信息同时说清原因:

```
model 'mimo-v2.6-flash' not in free catalog (upstream 7 peers, cheapest $0.02/$0.05 per M, no $0 peer)
```

## 3. 点名模型失败后被悄悄换成别的模型(中)

`AUTO_FALLBACK=1` 对**点名模型**也生效:你要 `deepseek-v4-flash`,它 402 了,网关就换到 `glm-5.3-flash`
把答案给你,response 里 `model` 也不是你点的那个。v1 没有这层行为。

**修复**:新增 `FALLBACK_NAMED`(默认 `0`)。默认下点名模型失败就照实报错;要恢复旧行为设 `FALLBACK_NAMED=1`。
`model=auto` / `antseed` / 空模型名不受影响,继续走多候选回退。

## 4. 402 / 429 冷却过长(低)

402(本轮没额度)、429(对端并发满)都是"换一个 peer 可能就好",之前按 900s 拉黑。现在:

- 探活遇到 402/429 先重试一次再判定
- 这类失败冷却改用 `SOFT_COOLDOWN`(默认 180s)

## 5. `model=auto` 的兜底名单会把已下架的模型当候选(低)

`seed_models()` 之前直接返回 `FALLBACK_ORDER`,不核对目录。配置里写死的
`deepseek-v4-flash,glm-5.3-flash,openai-gpt-oss-120b` 一旦某个被上游下架,
冷启动窗口里 `auto` 会先拿它去试,白白浪费一次尝试。现在只保留目录里真实存在的条目。

## 新增可调项(`/etc/antseed/gateway.env`)

```
SOFT_COOLDOWN=180          # 402/429 冷却,比 BLACKLIST_SECONDS 短
FALLBACK_NAMED=0           # 1=点名模型失败后换模型(默认 0 = 照实报错)
```

# v2.0.4 修复

`/health` 的 `ok` / `warming_up` 判断写错了:探活状态字段初值是 `0` 而不是 `None`,
`H.last_probe is None` 永远不成立,于是刚启动时 `/health` 仍是 `"ok": false, "warming_up": false`——
虽然这时 `model=auto` 已经能正常出结果了(靠 `v2.0.3` 的 seed 兜底)。改成 `not H.last_probe`。

# v2.0.3 修复

## 刚启动的那 30~50 秒里 `model=auto` 直接 503(中)

**现象**:`systemctl restart antseed-gateway` 之后马上调 API:

```json
{"error":{"message":"no healthy model available right now; check /health","type":"unavailable"}}
```

等 40 秒左右又自己好了,`/health` 里 `"healthy": []` 变成一串模型名。

**根因**:`auto` / `antseed` 的落点取自探活结果(`healthy`)。服务刚起来时首轮探活还没跑完(17 个候选、4 个并发、通过 4 个,约 40 秒),`healthy` 是空的,于是别名路由算不出候选,直接回"不可用"。装完立刻调一次 API 的人,看到的就是这个。

**修复**:

- `seed_models()`:探活结果为空时按 `FALLBACK_ORDER` → 模型目录顺序兜底,`auto` 立刻有落点,后续请求失败还能顺着候选往下试
- 首轮探活按 `FALLBACK_ORDER` 优先排序,让 `auto` 的落点最先被验证
- `/health` 增加 `warming_up` 与 `will_route_to`:探活没跑完时 `ok` 不再误报 `false`,并直接告诉你 `auto` 会落到哪个模型
- 安装器自检从"能列模型"升级为"能推理":等首轮探活出结果(≤90s),再真发一次 `model=auto` 的补全请求,成功才算通过

## 顺带

- `v2.0.2` 的 `/health` 字段是追加的,旧监控脚本不受影响

# v2.0.2 修复

## Anthropic 端点 `/v1/messages` 不解析 `auto` 别名(严重)

**现象**:OpenAI 兼容的 `/v1/chat/completions` 一切正常,但 Anthropic 客户端(claude 风格 base_url)一调就报:

```json
{"error":{"type":"model_not_found","code":"model_not_found",
          "message":"No policy-allowed peer currently serves model \"auto\"."}}
```

**根因**:v2 只在 `/v1/chat/completions` 上做了"别名解析 + 候选回退",其余路径直接原样透传。Anthropic 客户端习惯写 `model: auto`,于是 `auto` 被原封不动发给上游——上游没有叫 `auto` 的模型。

**修复**:

- 抽出一个统一的入口 `_model_request()`,凡请求体是"带 `model` 字段的 JSON"的路径都走它:`/v1/chat/completions`、`/v1/completions`、`/v1/embeddings`、`/v1/messages`(含 `/v1/messages/count_tokens`)
- 别名 `auto` / `antseed` / 空 model:先解析成当前最快的健康模型,再发上游;响应头照旧回填 `X-Antseed-Model` / `X-Antseed-Attempt`
- `FREE_ONLY=1` 的点名付费模型拦截对 Anthropic 路径同样生效(直接 400,不把 402 甩给客户端)
- 402/429/5xx/连接失败时 Anthropic 路径也会自动换候选
- 是否 SSE 不再只看请求里的 `stream` 字段,也看上游响应的 `Content-Type`:Anthropic 客户端有时不传 `stream`,但上游仍会回流
- 其余 `/v1/*`(音频、文件、批处理等非 JSON-model 结构)继续原样透传

# v2.0.1 修复

真机部署(Armbian/Ubuntu noble,aarch64)时暴露的两个问题。

## 1. buyer 单元漏了 `--port`,导致买家占掉网关端口(严重)

**现象**:装完之后局域网内 `http://<盒子>:8377/v1/models` 连接被拒;`systemctl status antseed-gateway` 显示 `activating (auto-restart)`,`journalctl` 里反复出现:

```
OSError: [Errno 98] Address already in use
antseed-gateway.service: Scheduled restart job, restart counter is at 121.
```

**根因**:v2 的 `antseed-buyer.service` 写成了 `ExecStart=... antseed buyer start`,**没有 `--port 8378`**。CLI 的默认端口是 8377,于是 buyer 先占了 8377,网关再想监听 `[::]:8377` 就撞端口,每 5 秒重启一次。v1 的 unit 里是有 `--port 8378` 的,是 v2 重写 unit 时漏掉的。网关的 `UPSTREAM` 仍指向 8378,所以探活也一直 `Connection refused`。

**修复**:`ExecStart=$NODE_BIN $ANTSEED_BIN buyer start --port $BUYER_PORT`。

**顺带的加固**:

- buyer 90 秒没就绪时,安装器会打印 `ss -ltn` 里 8378/8377 的实际占用情况;若发现网关端口已被别人占着,直接给出提示,不再只是"未就绪"
- 网关绑定失败不再甩 traceback:`EADDRINUSE` / `EACCES` / `EAFNOSUPPORT` 各翻译成一句人话并附排查命令;`::` 不可用时自动退到 `0.0.0.0`

## 2. 公网 IP 探测打印假的中断提示

**现象**:安装成功、最后也打印了"安装完成",但中间夹着两行

```
[antseed-gateway] 中断于第 1618 行 (exit 7);排错: bash -x install.sh
```

`exit 7` 是 `curl` 连不上。**根因**:`detect_ip()` 逐个试三个接口取公网 IP,失败的 `curl` 落在命令替换 `$( )` 里,而 `ERR` trap 被带进了子 shell,于是打了个"中断"——其实脚本继续跑完了。

**修复**:`detect_ip()` 内部单独开子 shell 并 `trap - ERR` + `set +e`,探测失败是正常流程,不再误报。

## 升级方式

```bash
# 盒子上的 v2 目录里
bash install.sh            # 幂等重装:复用 key 与节点身份,只换程序与 unit
# 或只换网关程序
bash upgrade.sh
```

---

# v2.0.0 改动说明

对照 v1 的 REVIEW.md(31 条,未随仓库提供)逐条说明落地情况。v1 是 [`v1/install.sh`](v1/install.sh)(505 行单文件),v2 拆成:

| 文件 | 作用 |
| --- | --- |
| `gateway.py` | 网关本体(777 行,纯标准库,可单独审/re/测) |
| `install.sh.tpl` | 安装器模板,`@@GATEWAY_PY@@` 处内嵌网关 |
| `install.sh` | **构建产物**:模板 + gateway.py,自包含、可直接 `bash` 跑 |
| `tools/build-install.sh` | 从 tpl + gateway.py 重新生成 install.sh,并反向校验逐字节一致 |
| `upgrade.sh` | 只换网关程序 + 重启 + 自检,失败自动回滚 |
| `README.md` | 配置项、接口、排错 |

改网关只改 `gateway.py`,然后 `bash tools/build-install.sh`;不要手改 `install.sh`。

## P0

| # | 问题 | v2 处理 |
| --- | --- | --- |
| 1 | `read -r API_KEY` 在 `set -e` 下 EOF 直接退出(已实测 exit=1) | 彻底删掉 stdin 交互。key 只从 `apikey=`/`API_KEY`/`--key=` 来,空则 `openssl rand -hex 16` 自动生成。`curl \| bash` 也不会再抢走脚本行 |
| 2 | 不认 `model: "antseed"` | 别名表 `auto`/`antseed`/空字符串 → 首选模型;响应头 `X-Antseed-Model` 回显真实模型 |
| 3 | `stream: true` 被整段缓冲 | `_relay_stream` 逐块转发 + `Transfer-Encoding: chunked` + 90s 空闲超时。实测首包 0.00s、3 个 chunk 按 0.4s 间隔到达 |
| 4 | `FREE_ONLY` 只过滤列表,路由层没约束 | `_candidates` 里按 `$0 报价 + type=text` 过滤;点名付费模型返回 **400 + 可选模型列表**,不再偷偷扣钱 |
| 5 | 402 起后台脚本后原样返回 402 | 402 标记该模型为"无额度"并从候选中剔除;`AUTO_ROTATE=0`(默认)时最终返回 **503 + Retry-After**,客户端明确知道可重试 |
| 6 | 无探活/无回退/无拉黑,列表每次实时打上游 | `probe_loop` 后台探活 + EWMA 延迟排序 + 连续失败拉黑 900s + 候选回退(`X-Antseed-Fallback: 1`)+ `MODELS_TTL` 缓存(带 stale 兜底与防击穿锁) |

## P1

| # | 问题 | v2 处理 |
| --- | --- | --- |
| 7 | `==` 比较 + 空 key 静默放行 | `hmac.compare_digest`;key 为空一律 401,只有显式 `ALLOW_NO_AUTH=1` 才放行 |
| 8 | 不绕 `http_proxy` | `build_opener(ProxyHandler({}))`,实测 `http_proxy=http://127.0.0.1:9` 下探活与转发照常 |
| 9 | 硬编码 `AF_INET6` | 按 `GATEWAY_BIND` 里有没有 `:` 选 family;`127.0.0.1` 就是纯 IPv4 |
| 10 | unit 写死 `/usr/bin/python3` | 安装时解析 `command -v python3` 的绝对路径写进 `ExecStart`,并校验 `>= 3.7` |
| 11 | 只转发 `Content-Type` | 白名单转发 `anthropic-version`/`anthropic-beta`/`Accept`/`User-Agent` 等;**入站鉴权头不下发上游**(实测 `x-api-key`/`Authorization` 不出现在上游) |
| 12 | `/health` 永远 `ok:true` | `ok` 由"是否探测过 + 是否有健康候选"决定;另有 `/v1/health/detail` 给内部看(含黑名单与统计)。`/health` 保持免鉴权且不泄漏模型清单 |
| 13 | 每次重装换身份 | 身份存 `/etc/antseed/buyer.env`,重装默认复用;要换才 `FORCE_ROTATE=1` |
| 14 | 锁在 `/tmp`(可预测、全局可写) | `/run/antseed/rotate.lock`,`mkdir` 原子锁 + 300s 过期清理 + trap 释放 |
| 15 | 在 `log_message` 里 `waitpid` | 用 `ThreadingMixIn.daemon_threads=True` + 显式 `waitpid(-1, WNOHANG)` 循环,不再依赖访问日志被调用 |
| 16 | 无 `Content-Length`/body/路径校验 | 非法 `Content-Length` → 400;超 `MAX_BODY_MB` → 413(带 `Connection: close`);路径白名单只放 `/v1/*` 与 `/health`;坏 JSON → 400 |
| 17 | 长请求绕过停止超时 | `TimeoutStopSec=30` + `SIGTERM` → 停止接新连接、等在途请求、`server_close()`,日志里写明"30s 后强制断" |

## P2

| # | 问题 | v2 处理 |
| --- | --- | --- |
| 18 | 只支持 apt,且无条件 `apt-get update` | apt / dnf / yum / pacman 四路;逐包判断是否已装,全齐时完全不碰包管理器 |
| 19 | Node 下载无校验、CLI 不锁版本 | `SHASUMS256.txt` + `sha256sum -c`,不匹配直接中止;`CLI_VERSION` 默认 `latest` 但可锁;失败自动补编译依赖重试一次 |
| 20 | 不检查 systemd | `command -v systemctl && [ -d /run/systemd/system ]`,容器/OpenVZ/WSL1 直接给明确原因 |
| 21 | `Environment="ANTSEED_API_KEY=..."` 直接拼接 | key 走 `/etc/antseed/gateway.env`(0600)+ `EnvironmentFile=`;字符白名单 `[A-Za-z0-9._~+/=-]`,非法直接拒;长度 < 16 警告 |
| 22 | 公网纯 HTTP、无限速 | 不改架构,但装完明确提示"要么绑 127.0.0.1,要么前面挂 TLS 反代";并发与 body 上限已限流 |
| 23 | 卸载不彻底 | `bash install.sh uninstall` 清 unit、drop-in、脚本、`/run/antseed`、legacy 路径;`--purge` 再删 `/etc/antseed` 与 `/root/.antseed`;保留/删除说清楚 |
| 24 | 无子命令 | `--help`/`--version`/`--dry-run`(非 root 也能跑)/`upgrade`/`uninstall [--purge]`,另有 `upgrade.sh` 只换网关且带回滚 |
| 25 | root 跑 + 无加固 | `NoNewPrivileges`/`PrivateTmp`/`ProtectSystem=full`/`ProtectHome`/`RestrictSUIDSGID`/`LockPersonality`/`MemoryMax=512M`/`LimitNOFILE` |
| 26 | `get_realip` 依赖外部服务 | `PUBLIC_HOST` 优先;否则多源探测(ipify → icanhazip → ip.sb),只接受 IPv4 字面量,再退 IPv6,最后 `127.0.0.1` |
| 27 | 死代码/一致性 | 无用的 `_models_free` 分支、重复 env 组装、`/tmp` 残留路径一并清掉;`/etc/profile.d/antseed.sh` 不再复制 key |

## 设计层面

| # | 结论 | v2 做法 |
| --- | --- | --- |
| 28 | 402 自动换身份 = 刷免费额度 | **`AUTO_ROTATE` 默认 0**。开启后也只做"换身份 + 重试同一模型一次",不循环;README 写明限流/封号风险 |
| 29 | 网关 root 跑 + 要能重启 buyer | 保留 root(否则无法 `systemctl restart antseed-buyer`),但把"能重启的权限"收窄成:网关只调 `systemctl start --no-block antseed-rotate.service`,真正改身份/重启的逻辑在 oneshot unit 里,网关进程内没有 `systemctl restart` 直调 |
| 30 | 505 行单文件不可评审 | 拆成 `gateway.py` + `install.sh.tpl` + 构建脚本;`install.sh` 是产物且被 `tools/build-install.sh` 逐字节反向校验 |
| 31 | 第三方两份产物互相矛盾 | 只吸收 patch 版网关的设计(探活 + 回退 + `_credit_models`),**不吸收** `install.sh` 里的 `AUTO_ROTATE=1` 与被 patch 删掉的轮换脚本 |

## 保留 v1 更好的地方(没被第三方带偏)

- 依赖增量检查,不再无条件 `apt-get update`
- 端口释放等待,且用 `if` 判断而不是 `grep | ...` 在 `pipefail` 下误判
- `FORCE_INSTALL` 已装则跳过 CLI(省时间)
- 过期锁清理时打印实际年龄

## v1 → v2 升级路径

```bash
# 1) 停旧服务(不删配置)
systemctl stop antseed-free-filter 2>/dev/null; systemctl disable antseed-free-filter 2>/dev/null
systemctl stop antseed-gateway 2>/dev/null

# 2) 记录旧身份,稍后确认被复用
grep -o 'ANTSEED_IDENTITY_HEX=[0-9a-f]\{64\}' /etc/systemd/system/antseed-buyer.service | head -1

# 3) 装 v2(默认复用身份,自动生成或沿用你给的 key)
apikey='<你的 key>' bash install.sh

# 4) 核对
curl -s http://127.0.0.1:8377/health | python3 -m json.tool
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8377/v1/health/detail
```

配置从 systemd unit 挪到了 `/etc/antseed/gateway.env`,身份挪到了 `/etc/antseed/buyer.env`。旧路径 `/etc/profile.d/antseed.sh`、`/usr/local/bin/antseed-free-filter.py`、`/tmp/antseed-rotate.lock` 会在卸载时清理。

## 落地过程中额外发现并修掉的问题

这些是把你 v1 的"重装即覆盖"逻辑接上 v2 的多文件结构之后,跑真实安装流程才暴露出来的:

| 问题 | 后果 | 处理 |
| --- | --- | --- |
| 重装不传 key 会重新生成一个新 key | 客户端全部 401,而你不知道为什么 | 重装时读 `gateway.env` 里的旧 key 复用;显式传 `--key=`/`apikey=` 才换,且换完提示"记得同步客户端" |
| 重装会把 `gateway.env` 整份重写 | 手工调过的 `STREAM_IDLE_TIMEOUT`/`BLACKLIST_SECONDS` 全丢 | 已存在则只 `sed` 更新**显式传入**的项(key / FREE_ONLY / 端口 / 监听 / UPSTREAM),其余原样保留;新增版本引入的键才追加 |
| 身份复用正则用了 `"\{0,1\}` | GNU sed 下不匹配,重装还是换身份(实测踩到) | 改成取值后 `tr -cd '0-9a-fA-F'` + 长度必须 64,`buyer.env` 与 v1 unit 两种格式都能读 |
| 网关 unit 用 `Requires=antseed-buyer.service` | buyer 彻底挂掉时网关被连带 stop,又被 `Restart=always` 拉起,5s 一次死循环 | 改成 `Wants=`,网关继续活着并返回 503,`/health` 能看出 buyer 挂了 |
| rotate 脚本轮换后打印身份前 8 位靠数问号截断 | 数字错了就打出整串 | 改 `cut -c1-8` |
| rotate unit 没传 `UPSTREAM` | 改了 `BUYER_PORT` 的机器上轮换后永远等不到就绪 | oneshot unit 里 `Environment=UPSTREAM=http://127.0.0.1:$BUYER_PORT` |
| 依赖检查只要 curl/wget 有一个就放行 | 只有 wget 的机器上健康检查/就绪探测静默失效 | curl 列为硬依赖,没有就装 |
| Node 校验文件 404 时报错难懂 | 用户不知道是版本号不存在 | 明确提示"用 `NODE_VERSION=vX.Y.Z` 指定实际版本" |
| 汇总里打印 `监听: :::8377` | 看着像笔误 | `::` 显示成 `[::]:8377` |

## 验证方式(可复现)

```bash
bash -n install.sh                     # 语法
bash install.sh --dry-run              # 全流程干跑,不需要 root、不改系统
bash install.sh --version
systemd-analyze verify <生成的三个 unit>

# 安装器状态机(在 user namespace + tmpfs 假根里跑,不碰真机)
# 首次安装 → 重装保 key/身份 → 手改 tuning 后只更新显式项 → 换 key →
# FORCE_ROTATE → upgrade 不动配置 → uninstall 保配置 → --purge 删干净 → 重装
```

## 验证记录

网关本体(`gateway.py`,同一份代码也内嵌在 `install.sh` 里)对着一个假上游做过 22 项点测,全过:

- 鉴权:无 key / 错 key → 401;`x-api-key` 也可入站
- 模型:`/v1/models` 里付费与 image 模型被过滤;`auto`/`antseed` 别名在前
- 路由:`model:"antseed"` → 200 且 `X-Antseed-Model` 指向真实模型;空 model 同效;点名付费模型 → 400 并列出可用模型
- 回退:500 的模型自动回退到健康模型,带 `X-Antseed-Fallback: 1`
- 流式:200 + `chunked`,首包 0.00s,总时长 1.20s,3 个 `data:` 块完整
- 安全:`/console/api/...` 与 `/v1/../../etc/passwd` → 404;2MB body → 413;坏 `Content-Length` → 400;坏 JSON → 400
- 其它:`/v1/health/detail` 200、`HEAD /health` 200;`AUTO_FALLBACK=0` 时 402 → 503 + `Retry-After`;`http_proxy` 设为死地址仍正常(绕代理生效);入站鉴权头不下发上游
- 从 `install.sh` 提取出的 `gateway.py` 与源文件逐字节一致,解出后直接启动同样通过
