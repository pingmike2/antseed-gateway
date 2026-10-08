# Antseed Gateway

一键部署 Antseed P2P 推理市场 buyer proxy，暴露 OpenAI 兼容 API。

## 特性

- 一键安装：`apikey=your_key bash install.sh`
- 自动安装 Node 24 + Antseed CLI
- 免费模型优先路由（`preferFreePeers: true`）
- systemd 服务管理
- OpenAI 兼容 API（`/v1/chat/completions`、`/v1/models`）

## 实测结果（2026-10-08）

| 模型 | 状态 | 备注 |
|------|------|------|
| deepseek-v4-flash | ✅ | 正常返回 |
| glm-5.3-flash | ✅ | 正常返回 |
| minimax-m3 | ✅ | 正常返回 |
| openai-gpt-oss-120b | ✅ | 正常返回 |
| gemma-4-e4b | ✅ | 正常返回 |
| llama-3.1-8b | ✅ | 正常返回 |
| mistral-nemo | ✅ | 正常返回 |
| glm-4.7-flash | ❌ | seller 要求 credits（非真免费） |
| qwen3-235b-instruct | ❌ | peer 连接失败 |
| nemotron-3-ultra-free | ❌ | peer 连接失败 |

**7/10 免费模型可用**，无需 USDC 押金。

## 快速开始

> **适用环境**
> - ✅ 有公网 IPv4 的 VPS
> - ✅ 纯 IPv6 VPS,并套 WARP(已实测可用)
> - ❌ NAT VPS(无公网端口映射,例如 Alpine/128MB 小机)不支持:buyer 常驻约 240MB 内存,且 Alpine 上官方 Node 24 不可用

```bash
# 不传 apikey 则自动生成；默认只返回免费模型
bash <(wget -qO- https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)

# 或自定义 apikey
apikey=your_key bash <(wget -qO- https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)

# 返回全部模型（含付费）
FREE_ONLY=0 bash <(wget -qO- https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)
```

## 使用

### 查看模型列表

```bash
curl http://127.0.0.1:8377/v1/models
```

### 调用模型

```bash
curl http://127.0.0.1:8377/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### Hermes 配置

在 `~/.hermes/config.yaml` 添加：

```yaml
model:
  provider: antseed
  default: antseed
  base_url: "http://127.0.0.1:8377/v1"
  api_mode: chat_completions

providers:
  antseed:
    name: Antseed
    api: http://127.0.0.1:8377/v1
    api_key: your_api_key
    transport: chat_completions
    default_model: antseed
    models:
      antseed:
        context_length: 200000
```

## 管理命令

```bash
# 查看状态
systemctl status antseed-gateway

# 查看日志
journalctl -u antseed-gateway -f

# 重启
systemctl restart antseed-gateway

# 停止
systemctl stop antseed-gateway

# 一键卸载（停止服务、删除配置和 systemd unit）
curl -fsSL https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh | bash -s uninstall
```

## 免费模型

当前可用的 $0 模型（需网络连通）：

- `deepseek-v4-flash`
- `glm-4.7-flash`
- `glm-5.3-flash`
- `MiniMax-M3`
- `openai-gpt-oss-120b`
- `qwen3-235b-instruct`
- `nemotron-3-ultra-free`

查看实时报价：

```bash
curl -s https://network.antseed.com/stats | jq -r '
  [.peers[].providers[].servicePricing // {} | to_entries[]
   | select(.value.inputUsdPerMillion == 0 and .value.outputUsdPerMillion == 0)
   | .key] | unique | .[]'
```

## 故障排查

### 服务启动失败

```bash
journalctl -u antseed-gateway -n 100
```

### 模型调用 502

```bash
# 检查网络连通性
curl -s http://127.0.0.1:8377/v1/models | python3 -c "import sys,json; m=json.load(sys.stdin)['data']; free=[x for x in m if any(p.get('inputUsdPerMillion',999)==0 and p.get('outputUsdPerMillion',999)==0 for p in x.get('peers',[]))]; print(f'Free: {len(free)} models'); [print(f'  - {x[\"id\"]}') for x in free[:20]]"

# 检查日志
journalctl -u antseed-gateway -n 50 | grep -i error
```

### Node 版本问题

```bash
node -v  # 应该是 v24.x
```

## 系统要求

- Linux x64/arm64
- root 权限
- 网络可访问 `network.antseed.com`

## 免责声明

本项目为非官方第三方项目,与 Antseed 及 Antseed Foundation 无关联,未经其认可或维护。免费模型由 Antseed P2P 网络上的独立节点提供,可用性、输出质量、延迟和隐私均无保证;请求内容可能被提供服务的节点看到,请勿发送敏感数据。部分模型可能报错(如 402 需充值、404/429/502)或产生费用。使用者须自行遵守 Antseed 条款、各上游模型提供方条款及所在地法律。因使用本软件(包括对外暴露 API 端口)造成的任何损失,作者不承担责任,风险自负。

This is an unofficial, third-party project, not affiliated with or endorsed by Antseed or the Antseed Foundation. Free models are served by independent peers on the Antseed P2P network with no guarantee of availability, quality, latency or privacy; requests may be visible to the serving peer. Some models may return errors or charge fees. You are responsible for complying with the Antseed terms, each upstream provider's terms, and applicable laws. The author is not liable for any loss arising from use of this software, including exposing the API endpoint publicly. Use at your own risk.

## License

[MIT](LICENSE) © 2026 [pingmike2](https://github.com/pingmike2)
