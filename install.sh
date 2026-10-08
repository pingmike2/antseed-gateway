#!/usr/bin/env bash
# Antseed Gateway 一键安装脚本
# 用法: curl -fsSL .../install.sh | apikey=your_key bash
# 或:   apikey=your_key bash install.sh
# 或:   echo "your_key" | bash install.sh
# 卸载: bash install.sh uninstall

set -euo pipefail

# 卸载模式
if [ "${1:-}" = "uninstall" ]; then
    echo "[antseed-gateway] 卸载 Antseed Gateway..."
    # 1. 停止并移除服务
    systemctl stop antseed-gateway.service antseed-buyer.service antseed-free-filter.service 2>/dev/null || true
    systemctl disable antseed-gateway.service antseed-buyer.service antseed-free-filter.service 2>/dev/null || true
    rm -f /etc/systemd/system/antseed-gateway.service /etc/systemd/system/antseed-buyer.service /etc/systemd/system/antseed-free-filter.service
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    # 2. 兜底:杀掉残留进程(端口 8377/8378 占用)
    pkill -f "antseed buyer start" 2>/dev/null || true
    pkill -f "antseed-free-filter.py" 2>/dev/null || true
    pkill -f "antseed gateway start" 2>/dev/null || true
    # 3. 本地数据与配置
    rm -rf /root/.antseed
    rm -f /etc/profile.d/antseed.sh
    # 4. 安装脚本写入的脚本文件
    rm -f /usr/local/bin/antseed-free-filter.py
    # 5. 命令链接:只删指向本脚本安装目录的链接,不误删系统已有的 node/npm
    NODE_DIR="/usr/local/node-v24.21.0"
    for f in antseed node npm npx; do
        link="/usr/local/bin/${f}"
        if [ -L "$link" ] && readlink "$link" | grep -q "^${NODE_DIR}/"; then
            rm -f "$link"
        fi
    done
    # 6. 删除本脚本安装的 Node 及其全局包(@antseed/cli 随之删除)
    rm -rf "$NODE_DIR"
    # 7. 验证残留
    left=$(ss -ltn 2>/dev/null | grep -cE ':(8377|8378)\b' || true)
    if [ "$left" -gt 0 ]; then
        echo "[antseed-gateway] 警告:端口 8377/8378 仍被占用,请执行: ss -ltnp | grep -E '8377|8378'"
    fi
    echo "[antseed-gateway] 卸载完成"
    exit 0
fi

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[antseed-gateway]${NC} $*"; }
warn() { echo -e "${YELLOW}[antseed-gateway]${NC} $*"; }
err()  { echo -e "${RED}[antseed-gateway]${NC} $*" >&2; exit 1; }

# 获取 API key（可选，不传则自动生成）
API_KEY="${apikey:-}"
if [ -z "$API_KEY" ]; then
    # 尝试从 stdin 读取
    if [ ! -t 0 ]; then
        read -r API_KEY
    fi
fi
if [ -z "$API_KEY" ]; then
    API_KEY="sk-antseed-$(openssl rand -hex 16)"
    log "已自动生成 API key"
fi

# 检查 root
if [ "$EUID" -ne 0 ]; then
    err "请用 root 运行: sudo apikey=your_key bash install.sh"
fi

# 检测系统
OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" != "Linux" ]; then
    err "仅支持 Linux，当前: $OS"
fi

case "$ARCH" in
    x86_64)  NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *) err "不支持的架构: $ARCH" ;;
esac

log "系统: $OS / $ARCH"

# 安装依赖
log "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq curl wget git build-essential python3 sqlite3 >/dev/null 2>&1

# 安装 Node 24
NODE_VERSION="v24.21.0"
NODE_DIR="/usr/local/node-${NODE_VERSION}"
if [ ! -x "${NODE_DIR}/bin/node" ]; then
    log "安装 Node ${NODE_VERSION}..."
    cd /tmp
    wget -q "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
    mkdir -p "$NODE_DIR"
    tar xf "node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -C "$NODE_DIR" --strip-components=1
    rm -f "node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
fi
export PATH="${NODE_DIR}/bin:$PATH"
ln -sf "${NODE_DIR}/bin/node" /usr/local/bin/node
ln -sf "${NODE_DIR}/bin/npm"  /usr/local/bin/npm
ln -sf "${NODE_DIR}/bin/npx"  /usr/local/bin/npx
log "Node $(node -v) 已就绪"

# 安装 Antseed CLI
log "安装 @antseed/cli..."
npm install -g @antseed/cli --no-audit --no-fund 2>&1 | tail -3

# 生成 identity
IDENTITY_HEX=$(openssl rand -hex 32)
log "生成节点身份: ${IDENTITY_HEX:0:16}..."

# 配置 Antseed
mkdir -p /root/.antseed
cat > /root/.antseed/config.json <<EOF
{
  "buyer": {
    "routingPreferences": {
      "preferFreePeers": true,
      "maxInputUsdPerMillion": 25,
      "minTrustScore": 0
    }
  }
}
EOF

# 保存环境变量
cat > /etc/profile.d/antseed.sh <<EOF
export ANTSEED_IDENTITY_HEX=${IDENTITY_HEX}
export ANTSEED_API_KEY=${API_KEY}
EOF
chmod 600 /etc/profile.d/antseed.sh
source /etc/profile.d/antseed.sh

# 确保 antseed 在 PATH 中
ANTSEED_BIN=""
if command -v antseed &>/dev/null; then
    ANTSEED_BIN=$(command -v antseed)
elif [ -f "/usr/local/node-v24.21.0/bin/antseed" ]; then
    ANTSEED_BIN="/usr/local/node-v24.21.0/bin/antseed"
else
    ANTSEED_BIN=$(find /usr/local -name antseed -type f 2>/dev/null | head -1 || true)
fi
if [ -z "$ANTSEED_BIN" ] || [ ! -f "$ANTSEED_BIN" ]; then
    echo -e "${RED}[错误] 找不到 antseed 可执行文件${NC}"
    exit 1
fi
ln -sf "$ANTSEED_BIN" /usr/local/bin/antseed 2>/dev/null || true

# 创建 buyer service（监听 127.0.0.1:8378）
cat > /etc/systemd/system/antseed-buyer.service <<EOF
[Unit]
Description=Antseed Buyer Proxy (internal)
After=network.target

[Service]
Type=simple
User=root
Environment="ANTSEED_IDENTITY_HEX=${IDENTITY_HEX}"
ExecStart=/usr/local/bin/antseed buyer start --port 8378
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antseed-buyer.service >/dev/null 2>&1

# 启动 buyer
log "启动 Antseed Buyer..."
systemctl start antseed-buyer.service
sleep 5

# 等待 buyer 就绪
log "等待 buyer 就绪..."
for i in $(seq 1 30); do
    if curl -s -m 2 http://127.0.0.1:8378/v1/models >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

FREE_ONLY="${FREE_ONLY:-1}"
# 对外网关:filter 自己鉴权(用户传入的 apikey 即唯一访问凭证),转发到内部 buyer
log "写入对外网关 (filter)..."
cat > /usr/local/bin/antseed-free-filter.py <<'PYEOF'
#!/usr/bin/env python3
"""对外 OpenAI 兼容网关:Bearer 鉴权 + 转发到内部 buyer(127.0.0.1:8378)。
FREE_ONLY=1 时 /v1/models 只返回 type=text 且存在 $0 报价 peer 的模型。"""
import http.server, json, os, socket, socketserver, urllib.request, urllib.error

UPSTREAM = "http://127.0.0.1:8378"
API_KEY = os.environ.get("ANTSEED_API_KEY", "")
FREE_ONLY = os.environ.get("FREE_ONLY", "1") == "1"
LISTEN = ("::", int(os.environ.get("GATEWAY_PORT", "8377")))  # 双栈:同时接受 IPv4 与 IPv6

def is_free(p):
    return p.get("inputUsdPerMillion", 999) == 0 and p.get("outputUsdPerMillion", 999) == 0

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _auth_ok(self):
        if not API_KEY:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {API_KEY}"

    def _send(self, status, body, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _err(self, status, msg):
        self._send(status, json.dumps({"error": {"message": msg}}).encode())

    def _forward(self):
        if not self._auth_ok():
            return self._err(401, "invalid api key")
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length > 0 else None
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command,
                                     headers={"Content-Type": self.headers.get("Content-Type", "application/json")})
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                data = resp.read()
                self._send(resp.status, data, resp.headers.get("Content-Type", "application/json"))
        except urllib.error.HTTPError as e:
            self._send(e.code, e.read() or b"{}")
        except Exception as e:
            self._err(502, f"upstream error: {e}")

    def do_GET(self):
        if self.path.split("?")[0] == "/v1/models" and FREE_ONLY:
            return self._models_free()
        if self.path == "/health":
            return self._send(200, b'{"ok":true}')
        return self._forward()

    def do_HEAD(self):
        return self._forward()

    def do_POST(self):
        return self._forward()

    def _models_free(self):
        if not self._auth_ok():
            return self._err(401, "invalid api key")
        try:
            with urllib.request.urlopen(UPSTREAM + "/v1/models", timeout=120) as resp:
                data = json.loads(resp.read())
        except Exception as e:
            return self._err(502, f"upstream error: {e}")
        out = []
        for m in data.get("data", []):
            # 只保留文本模型:图片等非 chat 模型走 chat/completions 会被上游 400
            if m.get("type") != "text":
                continue
            peers = [p for p in m.get("peers", []) if is_free(p)]
            if peers:
                m["peers"] = peers
                out.append(m)
        data["data"] = out
        self._send(200, json.dumps(data, ensure_ascii=False).encode())

    def log_message(self, fmt, *args):
        pass

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    S(LISTEN, H).serve_forever()
PYEOF
chmod +x /usr/local/bin/antseed-free-filter.py

cat > /etc/systemd/system/antseed-gateway.service <<EOF
[Unit]
Description=Antseed Gateway (public OpenAI-compatible API)
After=network.target antseed-buyer.service
Requires=antseed-buyer.service

[Service]
Type=simple
User=root
Environment="ANTSEED_API_KEY=${API_KEY}"
Environment="FREE_ONLY=${FREE_ONLY}"
Environment="GATEWAY_PORT=8377"
ExecStart=/usr/bin/python3 /usr/local/bin/antseed-free-filter.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antseed-gateway.service >/dev/null 2>&1
log "启动对外网关..."
systemctl restart antseed-gateway.service
sleep 3

if systemctl is-active --quiet antseed-gateway.service && systemctl is-active --quiet antseed-buyer.service; then
    log "服务运行中"
else
    warn "服务启动失败,查看日志: journalctl -u antseed-gateway -n 50"
    exit 1
fi

# 获取真实 IP(优先 IPv4 公网,必要时回退 IPv6)
get_realip() {
    ip=$(curl -4 -sm 2 ip.sb)
    ipv6() { curl -6 -sm 2 ip.sb; }
    if [ -z "$ip" ]; then
        echo "[$(ipv6)]"
    elif curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        echo "[$(ipv6)]"
    else
        echo "$ip"
    fi
}
VPS_IP=$(get_realip)

echo ""
echo "========================================"
echo "  Antseed Gateway 安装完成"
echo "========================================"
echo ""
echo "  Proxy:   http://${VPS_IP}:8377/v1"
echo "  API Key: ${API_KEY}"
echo "  模型过滤: FREE_ONLY=${FREE_ONLY}(1=仅免费,0=全部)"
echo ""
echo "  Hermes 配置:"
echo "    base_url: http://${VPS_IP}:8377/v1"
echo "    api_key:  ${API_KEY}"
echo ""
echo "  常用命令:"
echo "    systemctl status antseed-gateway"
echo "    journalctl -u antseed-gateway -f"
echo "    curl -H \"Authorization: Bearer ${API_KEY}\" http://127.0.0.1:8377/v1/models"
echo ""
echo "========================================"
