# Contributing

本文件写给**接手这个仓库的 AI 编码代理**(Claude Code / Codex / OpenCode / dsh / Copilot Agent 等),也适用于人类贡献者。人类读者可跳过标有 `AI:` 的段落。

---

## 0. 三十秒建立上下文

| 事实 | 含义 |
| --- | --- |
| `install.sh` 是**构建产物** | 手改必被下次 build 冲掉;改 `install.sh.tpl` 或 `gateway.py` |
| `gateway.py` 有**两份** | 源文件 + `install.sh` 里嵌的那份,由 `tools/build-install.sh` 保证逐字节一致 |
| `install.sh` **必须在仓库根目录** | 一键安装直接读 `raw.githubusercontent.com/.../main/install.sh` |
| 网关只依赖 **Python 3.7+ 标准库** | 不要引入 requests / pydantic / 任何第三方包 |
| 服务管理用 **systemd**,不是 supervisor / docker | 目标机是 Debian/Ubuntu VPS |

`AI:` 进入仓库先跑这三条,任何一条失败都先修环境,别开始改代码:

```bash
python3 tests/test_gateway.py        # 期望 59 passed, 0 failed
bash tools/build-install.sh --check  # 期望三行 OK
bash -n install.sh                   # 期望无输出
```

---

## 1. 改东西的正确姿势

### 改网关行为 → `gateway.py`

1. 只改 `gateway.py`
2. `python3 tests/test_gateway.py` — 现有测试必须全绿
3. 新增行为 → **同时加测试**(见第 3 节)
4. `bash tools/build-install.sh` — 重新生成 `install.sh`
5. `bash install.sh --dry-run` — 确认流程还走得通

### 改安装器逻辑 → `install.sh.tpl`

1. 只改 `install.sh.tpl`
2. `bash tools/build-install.sh`(**会重新生成 `install.sh`**)
3. `bash -n install.sh`
4. 有条件的话,在一次性 VPS 上实跑一遍

### 绝对禁止

- ❌ 直接编辑 `install.sh`(它是产物)
- ❌ 只改 `gateway.py` 不 build(装上去的是旧代码)
- ❌ 在 `gateway.py` 里写独立成行的 `ANTSEED_GATEWAY_PY_EOF`(会提前闭合 heredoc)
- ❌ 删除 `tools/build-install.sh` 的任一道闸门(见第 4 节)
- ❌ 提交 `.env` / 真实 API key / 真实 VPS IP / 私人域名
- ❌ 引入第三方 Python 依赖

---

## 2. 构建链是怎么咬合的

```
install.sh.tpl  ──┐
                  ├── tools/build-install.sh ──> install.sh(自包含,被用户一键执行)
gateway.py      ──┘
```

`install.sh.tpl` 里只有一行占位:

```bash
@GATEWAY_PY_MARK@
```

构建时被替换成整个 `gateway.py`。**占位行必须单独成行**(按行首等值匹配,不是字符串替换)——曾经有人把它写成 `write_file ... 0755 @GATEWAY_PY_MARK@`,结果整段 Python 被拼到文件顶部,`bash` 把 Python 代码当 shell 执行,吐出一屏 `log: command not found`。

### 占位行必须出现在 `安装脚本本体结束` 标记之后

`install.sh.tpl` 里有一行守卫注释:

```
# ================= 安装脚本本体结束 =================
```

构建脚本强制要求占位行出现在这行**之后**。这是防止"入口扫描"式误改把 Python 块拼到文件顶部的最后一道闸。

---

## 3. 测试

`tests/test_gateway.py` 是**纯标准库**的行为测试:起一个假上游 HTTP 服务 + 真实网关进程,断言状态码与响应头。不碰线上,不需要真 buyer。

```bash
python3 tests/test_gateway.py            # 全部
python3 tests/test_gateway.py -k 流式     # 只跑名字含"流式"的
```

`AI:` 新增功能时的最低要求:

- **每个改动至少一条测试断言**。改回退逻辑 → 断言 `X-Antseed-Fallback`;改鉴权 → 断言 401 与 `Connection: close`;改流式 → 断言 `Transfer-Encoding: chunked` + 块数。
- 测试名用中文短句 + 断言结果(`PASS 流式 3 个 data 块完整`),便于 CI 日志扫读。
- 不要联网、不要 sleep 超过 2s、不要依赖外部端口。

---

## 4. `tools/build-install.sh` 的三道闸门(别删)

| 闸门 | 作用 | 失败信息 |
| --- | --- | --- |
| `bash -n` | 生成物语法 | `install.sh 语法检查失败` |
| heredoc 结构 | 起点恰好 1 处、内嵌块在起点与终点之间、尾巴没被截断 | `找不到 heredoc 起点/终点` |
| 反向逐字节比对 | 抽回内嵌块与 `gateway.py` 一致 | `内嵌块与 gateway.py 不一致` |

**`--check` 模式**供 CI 用:不一致就非零退出,不写任何文件。

`AI:` 如果你改了这个脚本,必须保证它**幂等**——连续跑两次输出 `OK install.sh 已是最新`。`PY_BYTES` 回填是唯一会破坏幂等的点:比对前必须把它还原成占位值,否则每次 build 都报假 diff。

---

## 5. 提交

Conventional Commits,一句话说清根因:

```
fix(build): 结构闸门 + 幂等自校验 + dry-run 不再写内嵌块
feat(gateway): 402 时按需轮换节点身份
docs: 手动轮换命令补 bash 前缀
```

`AI:` 提交前自检清单:

- [ ] `python3 tests/test_gateway.py` → 0 failed
- [ ] `bash tools/build-install.sh --check` → 三行 OK
- [ ] `git status` 里没有 `install.sh` 未 build 的漂移
- [ ] diff 里没有任何密钥、IP、域名、内网路径
- [ ] 改的是 `gateway.py` / `install.sh.tpl`,不是 `install.sh`

**不要自己 push 到 `main`**,除非维护者明确授权。开 PR,CI 通过后由维护者合并。

---

## 6. CI

`.github/workflows/ci.yml` 在每次 push / PR 上跑:

1. `bash tools/build-install.sh --check` — 构建产物与源同步
2. `bash -n install.sh` — 语法
3. `python3 tests/test_gateway.py` — 行为测试
4. `bash install.sh --dry-run` — 安装流程干跑

`AI:` CI 红了先看是哪一步,别直接改测试让它绿。

---

## 7. 本地验证安装器(不炸生产)

```bash
# 干跑:不写系统,只打印会做什么
bash install.sh --dry-run

# 真装(需要 root + systemd,Docker 里要 --privileged 并挂 /sys/fs/cgroup)
sudo apikey=sk-antseed-测试用 bash install.sh

# 装完自检
bash install.sh status
curl -s http://127.0.0.1:8377/health | python3 -m json.tool

# 卸载(保留配置与身份)
bash install.sh uninstall

# 彻底清(连 /etc/antseed 与节点身份)
bash install.sh uninstall --purge
```

---

## 8. 排错速查(改代码前先看)

| 现象 | 根因 |
| --- | --- |
| `log: command not found` 一屏 | 内嵌 Python 块跑到 heredoc 外面了 → 跑 `bash tools/build-install.sh` |
| `env: 'node': No such file` | 内置 Node 装好了但 PATH 没生效 → 用 `$NODE_BIN` 绝对路径,别用裸 `node` |
| build 每次都报 diff | 比对前没把 `PY_BYTES` 还原成占位值 |
| `--dry-run` 把真程序覆盖了 | `write_file` 没在 dry-run 时短路 |
| 装完 `/v1/models` 只有 `auto` | buyer 没就绪,`journalctl -u antseed-buyer -n 50` |
| 全部 503 | 全模型被拉黑,看 `/v1/health/detail` |
