#!/usr/bin/env bash
# Antseed Gateway 一键安装脚本
# 用法: apikey=your_key bash install.sh
# 或:   echo "your_key" | bash install.sh

set -euo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[antseed-gateway]${NC} $*"; }
warn() { echo -e "${YELLOW}[antseed-gateway]${NC} $*"; }
err()  { echo -e "${RED}[antseed-gateway]${NC} $*" >&2; exit 1; }

# 获取 API key
API_KEY="${apikey:-}"
if [ -z "$API_KEY" ]; then
    # 尝试从 stdin 读取
    if [ ! -t 0 ]; then
        read -r API_KEY
    fi
fi
if [ -z "$API_KEY" ]; then
    err "请设置 apikey: apikey=your_key bash install.sh"
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

# 创建 systemd service
cat > /etc/systemd/system/antseed-gateway.service <<EOF
[Unit]
Description=Antseed Gateway Buyer Proxy
After=network.target

[Service]
Type=simple
User=root
Environment="ANTSEED_IDENTITY_HEX=${IDENTITY_HEX}"
Environment="ANTSEED_API_KEY=${API_KEY}"
ExecStart=/usr/local/bin/antseed buyer start
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antseed-gateway.service >/dev/null 2>&1

# 启动
log "启动 Antseed Gateway..."
systemctl start antseed-gateway.service
sleep 5

# 检查状态
if systemctl is-active --quiet antseed-gateway.service; then
    log "Antseed Gateway 运行中"
else
    warn "服务启动失败，查看日志: journalctl -u antseed-gateway -n 50"
    exit 1
fi

# 等待 proxy 就绪
log "等待 proxy 就绪..."
for i in $(seq 1 30); do
    if curl -s -m 2 http://127.0.0.1:8377/v1/models >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# 输出信息
echo ""
echo "========================================"
echo "  Antseed Gateway 安装完成"
echo "========================================"
echo ""
echo "  Proxy:  http://127.0.0.1:8377/v1"
echo "  API Key: ${API_KEY}"
echo ""
echo "  Hermes 配置:"
echo "    base_url: http://127.0.0.1:8377/v1"
echo "    api_key:  ${API_KEY}"
echo ""
echo "  常用命令:"
echo "    systemctl status antseed-gateway"
echo "    journalctl -u antseed-gateway -f"
echo "    curl http://127.0.0.1:8377/v1/models"
echo ""
echo "========================================"
