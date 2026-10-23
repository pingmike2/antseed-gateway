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
    # 尝试从 stdin 读取(非交互/EOF 时跳过,走自动生成)
    if [ ! -t 0 ]; then
        read -r API_KEY || API_KEY=""
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
# 优先使用系统已安装的 Node（要求 >= v24）。若系统已有可用 Node，则不下载、
# 不覆盖系统 node/npm/npx，直接沿用，避免破坏系统环境。
NODE_VERSION="v24.21.0"
NODE_DIR="/usr/local/node-${NODE_VERSION}"
SYSTEM_NODE="${SYSTEM_NODE:-1}"   # 置 0 可强制走内置 v24.21.0 安装

USE_SYSTEM=0
if [ "$SYSTEM_NODE" != "0" ] && command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 24 ] 2>/dev/null; then
        USE_SYSTEM=1
    fi
fi

if [ "$USE_SYSTEM" = "1" ]; then
    # 复用系统 Node：npm/npx 同样来自系统 PATH
    SYSTEM_NODE_BIN="$(dirname "$(command -v node)")"
    SYSTEM_NPM="$(command -v npm || true)"
    export PATH="$SYSTEM_NODE_BIN:$PATH"
    log "检测到系统 Node $(node -v)，直接使用（跳过下载 v24.21.0）"
    if [ -z "$SYSTEM_NPM" ]; then
        warn "未在 PATH 找到 npm，尝试用系统 node 全局安装 @antseed/cli 时可能失败"
    fi
else
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
fi
log "Node $(node -v) 已就绪"

# 安装 Antseed CLI
log "安装 @antseed/cli..."
npm install -g @antseed/cli --no-audit --no-fund 2>&1 | tail -3

# 免费模型开关(默认 1;FREE_ONLY=0 返回全部模型)
FREE_ONLY="${FREE_ONLY:-1}"

# 生成 identity
IDENTITY_HEX=$(openssl rand -hex 32)
log "生成节点身份: ${IDENTITY_HEX:0:16}..."

# 配置 Antseed:FREE_ONLY=1 时把路由价格上限压到 0,buyer 只走 $0 报价 peer(减少被路由进付费 peer 吃 402)
if [ "$FREE_ONLY" = "1" ]; then PRICE_CAP=0; else PRICE_CAP=25; fi
mkdir -p /root/.antseed
cat > /root/.antseed/config.json <<EOF
{
  "buyer": {
    "routingPreferences": {
      "preferFreePeers": true,
      "maxInputUsdPerMillion": ${PRICE_CAP},
      "maxOutputUsdPerMillion": ${PRICE_CAP},
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

# 对外网关:filter 自己鉴权(用户传入的 apikey 即唯一访问凭证),转发到内部 buyer
log "写入对外网关 (filter)..."
cat > /usr/local/bin/antseed-free-filter.py <<'PYEOF'
#!/usr/bin/env python3
"""Antseed 对外 OpenAI 兼容网关(改进版)

相比原版:
  1. 后台探活:定期对每个候选模型发 max_tokens=1 的小请求,/v1/models 只返回最近探测通过的模型
  2. 失败回退:402/404/429/5xx/连接失败/首字节超时 -> 自动换下一个健康模型(可关)
  3. 失败拉黑:连续失败的模型冷却一段时间,不再被路由
  4. 流式透传:stream=true 时边收边发(chunked),不再整段缓冲
  5. 鉴权:必须设置 API key(除非显式 ALLOW_NO_AUTH=1),常量时间比较
  6. 402 自动换身份:AUTO_ROTATE=1 时,先轮换节点身份再重试同一模型;
     轮换后仍 402 → 判定为真·付费模型,拉黑并走回退
  7. 模型名 "auto" / "antseed" -> 自动选当前最快的健康模型

只依赖 Python 3 标准库。
"""
import hmac
import http.client
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# ---------------- 配置 ----------------
UPSTREAM = os.environ.get("UPSTREAM", "http://127.0.0.1:8378")
API_KEY = os.environ.get("ANTSEED_API_KEY", "")
ALLOW_NO_AUTH = os.environ.get("ALLOW_NO_AUTH", "0") == "1"
FREE_ONLY = os.environ.get("FREE_ONLY", "1") == "1"
PORT = int(os.environ.get("GATEWAY_PORT", "8377"))
BIND = os.environ.get("GATEWAY_BIND", "::")

PROBE_INTERVAL = int(os.environ.get("PROBE_INTERVAL", "300"))      # 探活周期(秒)
PROBE_TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "45"))         # 单次探活超时
PROBE_WORKERS = int(os.environ.get("PROBE_WORKERS", "4"))          # 并发探活数
HEALTHY_TTL = int(os.environ.get("HEALTHY_TTL", str(PROBE_INTERVAL * 3)))  # 成功结果有效期
FAIL_THRESHOLD = int(os.environ.get("FAIL_THRESHOLD", "2"))        # 连续失败几次拉黑
BLACKLIST_SECONDS = int(os.environ.get("BLACKLIST_SECONDS", "900"))

AUTO_FALLBACK = os.environ.get("AUTO_FALLBACK", "1") == "1"        # 失败自动换模型
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))            # 单请求最多尝试几个模型
# 优先回退顺序(逗号分隔),不在其中的健康模型按延迟排在后面
FALLBACK_ORDER = [m.strip() for m in os.environ.get("FALLBACK_ORDER", "").split(",") if m.strip()]
STREAM_IDLE_TIMEOUT = int(os.environ.get("STREAM_IDLE_TIMEOUT", "90"))   # 流式:两次收包最长间隔
NONSTREAM_TIMEOUT = int(os.environ.get("NONSTREAM_TIMEOUT", "300"))     # 非流式:整体等待
AUTO_NAMES = {"auto", "antseed"}
RETRYABLE = {402, 404, 408, 409, 425, 429, 500, 502, 503, 504}

# 402 自动换身份:先轮换节点身份重试,换身份后仍 402 才判定该模型需要付费
AUTO_ROTATE = os.environ.get("AUTO_ROTATE", "1") == "1"
ROTATE_SCRIPT = os.environ.get("ROTATE_SCRIPT", "/usr/local/bin/antseed-rotate-identity.sh")
BUYER_UNIT = "/etc/systemd/system/antseed-buyer.service"
_rotate_lock = threading.Lock()
_credit_models = set()
_probe_402 = set()

# 上游是本机 buyer,绕过系统 http_proxy 环境变量
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
urlopen = _OPENER.open

if not API_KEY and not ALLOW_NO_AUTH:
    sys.exit("ANTSEED_API_KEY 未设置。对外暴露的网关必须鉴权;确需关闭请设 ALLOW_NO_AUTH=1")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def is_free(p):
    return p.get("inputUsdPerMillion", 999) == 0 and p.get("outputUsdPerMillion", 999) == 0


# ---------------- 健康状态 ----------------
class Health:
    def __init__(self):
        self.lock = threading.Lock()
        self.catalog = {}   # model_id -> 上游 /v1/models 里的条目
        self.state = {}     # model_id -> dict(ok_at, latency, fails, banned_until, last_error)
        self.last_probe = 0

    def _st(self, m):
        return self.state.setdefault(m, {"ok_at": 0, "latency": None, "fails": 0,
                                         "banned_until": 0, "last_error": None})

    def success(self, m, latency=None):
        with self.lock:
            s = self._st(m)
            s["ok_at"] = time.time()
            if latency is not None:
                s["latency"] = latency if s["latency"] is None else 0.7 * s["latency"] + 0.3 * latency
            s["fails"] = 0
            s["banned_until"] = 0
            s["last_error"] = None

    def failure(self, m, err):
        with self.lock:
            s = self._st(m)
            s["fails"] += 1
            s["last_error"] = str(err)[:200]
            if s["fails"] >= FAIL_THRESHOLD:
                s["banned_until"] = time.time() + BLACKLIST_SECONDS
                log(f"[ban] {m} 冷却 {BLACKLIST_SECONDS}s: {s['last_error']}")

    def healthy(self):
        """按优先级返回健康模型列表"""
        now = time.time()
        with self.lock:
            ok = [m for m, s in self.state.items()
                  if m in self.catalog and s["banned_until"] < now and now - s["ok_at"] < HEALTHY_TTL]
            lat = {m: (self.state[m]["latency"] or 999) for m in ok}
        pref = [m for m in FALLBACK_ORDER if m in ok]
        rest = sorted((m for m in ok if m not in pref), key=lambda m: lat[m])
        return pref + rest

    def banned(self, m):
        with self.lock:
            return self._st(m)["banned_until"] > time.time()

    def reset_all(self):
        with self.lock:
            for s in self.state.values():
                s["fails"] = 0
                s["banned_until"] = 0
                s["last_error"] = None

    def snapshot(self):
        now = time.time()
        with self.lock:
            out = {}
            for m in self.catalog:
                s = self._st(m)
                out[m] = {
                    "healthy": s["banned_until"] < now and now - s["ok_at"] < HEALTHY_TTL,
                    "latency_s": round(s["latency"], 2) if s["latency"] else None,
                    "fails": s["fails"],
                    "banned_for_s": max(0, int(s["banned_until"] - now)),
                    "last_ok_ago_s": int(now - s["ok_at"]) if s["ok_at"] else None,
                    "last_error": s["last_error"],
                }
            return out


H = Health()


def current_identity():
    try:
        with open(BUYER_UNIT) as f:
            for line in f:
                if "ANTSEED_IDENTITY_HEX=" in line:
                    return line.split("ANTSEED_IDENTITY_HEX=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return ""


def rotate_wait():
    """同步轮换 buyer 节点身份并等待就绪;身份确实变化时清空付费模型判定与拉黑。"""
    with _rotate_lock:
        before = current_identity()
        try:
            subprocess.run([ROTATE_SCRIPT], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=240)
        except Exception:
            pass
        deadline = time.time() + 150
        while time.time() < deadline:
            try:
                urlopen(UPSTREAM + "/v1/models", timeout=5)
                break
            except Exception:
                time.sleep(2)
        after = current_identity()
        if after and after != before:
            _credit_models.clear()
            H.reset_all()
            log(f"[rotate] identity {before[:8]} -> {after[:8]}")
            return True
        return False


# ---------------- 上游 ----------------
def fetch_catalog():
    with urlopen(UPSTREAM + "/v1/models", timeout=60) as r:
        data = json.loads(r.read())
    cat = {}
    for m in data.get("data", []):
        if m.get("type", "text") != "text":
            continue
        if FREE_ONLY:
            peers = [p for p in m.get("peers", []) if is_free(p)]
            if not peers:
                continue
            m = dict(m, peers=peers)
        cat[m["id"]] = m
    return cat


def probe(model):
    body = json.dumps({"model": model, "max_tokens": 1, "stream": False,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(UPSTREAM + "/v1/chat/completions", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urlopen(req, timeout=PROBE_TIMEOUT) as r:
            data = json.loads(r.read() or b"{}")
        if not data.get("choices"):
            raise ValueError("no choices in response")
        _probe_402.discard(model)
        H.success(model, time.time() - t0)
        return True
    except urllib.error.HTTPError as e:
        H.failure(model, f"HTTP {e.code}: {(e.read() or b'')[:120]!r}")
        if e.code == 402:
            _probe_402.add(model)
    except Exception as e:
        H.failure(model, e)
    return False


def probe_loop():
    while True:
        try:
            cat = fetch_catalog()
            with H.lock:
                H.catalog = cat
            todo = [m for m in cat if not H.banned(m)]
            with ThreadPoolExecutor(PROBE_WORKERS) as ex:
                results = list(ex.map(probe, todo))
                if AUTO_ROTATE and _probe_402 and sum(results) == 0:
                    log("[probe] 候选全部 402,轮换节点身份后重探一轮")
                    rotate_wait()
                    results = list(ex.map(probe, sorted(_probe_402)))
            H.last_probe = time.time()
            log(f"[probe] 候选 {len(cat)},本轮探测 {len(todo)},通过 {sum(results)},"
                f"当前健康: {', '.join(H.healthy()) or '无'}")
        except Exception as e:
            log(f"[probe] 拉取模型列表失败: {e}")
        time.sleep(PROBE_INTERVAL)


def open_upstream(path, body, headers, timeout):
    """返回 (status, headers, HTTPResponse);连接失败抛异常"""
    u = urllib.request.urlparse(UPSTREAM)
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    conn.request("POST", path, body=body, headers=headers)
    resp = conn.getresponse()
    return resp, conn


# ---------------- HTTP 服务 ----------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "antseed-gateway"

    def log_message(self, fmt, *args):
        pass

    # --- 工具 ---
    def _auth_ok(self):
        if not API_KEY:
            return True
        got = self.headers.get("Authorization", "")
        return hmac.compare_digest(got.encode(), f"Bearer {API_KEY}".encode())

    def _send(self, status, body, ctype="application/json", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj, extra=None):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode(), extra=extra)

    def _err(self, status, msg):
        self._json(status, {"error": {"message": msg, "type": "gateway_error"}})

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n > 0 else b""

    # --- 路由 ---
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            healthy = H.healthy()
            return self._json(200, {"ok": bool(healthy), "healthy": healthy,
                                    "last_probe_ago_s": int(time.time() - H.last_probe) if H.last_probe else None})
        if not self._auth_ok():
            return self._err(401, "invalid api key")
        if path == "/v1/models":
            return self._models()
        if path == "/v1/health/detail":
            return self._json(200, H.snapshot())
        return self._passthrough(b"")

    def do_POST(self):
        if not self._auth_ok():
            return self._err(401, "invalid api key")
        body = self._body()
        if self.path.split("?")[0] == "/v1/chat/completions":
            return self._chat(body)
        return self._passthrough(body)

    def _models(self):
        healthy = H.healthy()
        with H.lock:
            cat = dict(H.catalog)
        # 启动初期还没探测完时,退回原始候选,避免列表为空
        ids = healthy if (healthy or H.last_probe) else list(cat)
        data = []
        snap = H.snapshot()
        for m in ids:
            item = dict(cat.get(m, {"id": m, "object": "model"}))
            item["x_latency_s"] = snap.get(m, {}).get("latency_s")
            data.append(item)
        if healthy:
            data.insert(0, {"id": "auto", "object": "model", "owned_by": "gateway",
                            "x_routes_to": healthy[0]})
        self._json(200, {"object": "list", "data": data})

    def _passthrough(self, body):
        req = urllib.request.Request(UPSTREAM + self.path, data=body or None, method=self.command,
                                     headers={"Content-Type": self.headers.get("Content-Type", "application/json")})
        try:
            with urlopen(req, timeout=NONSTREAM_TIMEOUT) as r:
                self._send(r.status, r.read(), r.headers.get("Content-Type", "application/json"))
        except urllib.error.HTTPError as e:
            self._send(e.code, e.read() or b"{}")
        except Exception as e:
            self._err(502, f"upstream error: {e}")

    def _candidates(self, requested):
        healthy = H.healthy()
        if requested in AUTO_NAMES or not requested:
            first = healthy[:1]
        elif AUTO_FALLBACK and (H.banned(requested) or requested in _credit_models) and healthy:
            first = []          # 指定的模型正在冷却,直接走回退
        else:
            first = [requested]
        if not AUTO_FALLBACK:
            return first
        rest = [m for m in healthy if m not in first]
        return (first + rest)[:MAX_ATTEMPTS]

    def _chat(self, raw):
        self._headers_sent = False
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._err(400, "invalid JSON body")
        requested = payload.get("model", "")
        stream = bool(payload.get("stream"))
        cands = self._candidates(requested)
        if not cands:
            return self._err(503, "no healthy model available right now; check /health")

        rotated = False
        last = (502, b'{"error":{"message":"all attempts failed"}}')
        i = 0
        while i < len(cands):
            model = cands[i]
            payload["model"] = model
            body = json.dumps(payload).encode()
            hdrs = {"Content-Type": "application/json",
                    "Accept": "text/event-stream" if stream else "application/json"}
            t0 = time.time()
            conn = None
            try:
                resp, conn = open_upstream(self.path, body, hdrs,
                                           STREAM_IDLE_TIMEOUT if stream else NONSTREAM_TIMEOUT)
                if (resp.status == 402 and AUTO_ROTATE and not rotated
                        and model not in _credit_models and os.path.exists(ROTATE_SCRIPT)):
                    resp.read()
                    rotated = True
                    log(f"[chat] {model} -> 402,疑似节点身份额度耗尽,轮换身份后重试同一模型")
                    rotate_wait()
                    continue  # 同一模型再试一次
                if resp.status >= 400:
                    err_body = resp.read() or b"{}"
                    last = (resp.status, err_body)
                    if resp.status == 402 and rotated:
                        _credit_models.add(model)   # 换身份仍 402:真·付费模型
                    if resp.status in RETRYABLE:
                        H.failure(model, f"HTTP {resp.status}")
                        log(f"[chat] {model} -> {resp.status},尝试下一个 ({i + 1}/{len(cands)})")
                        i += 1
                        continue
                    return self._send(resp.status, err_body)  # 400 之类的请求错误,不重试

                extra = {"X-Antseed-Model": model, "X-Antseed-Attempt": str(i + 1)}
                if stream:
                    self._relay_stream(resp, extra)
                else:
                    data = resp.read()
                    self._send(resp.status, data, resp.getheader("Content-Type", "application/json"), extra)
                H.success(model, time.time() - t0 if not stream else None)
                return
            except (socket.timeout, TimeoutError, ConnectionError, http.client.HTTPException, OSError) as e:
                if getattr(self, "_headers_sent", False):
                    # 已开始向客户端输出,不能再回退
                    H.failure(model, f"mid-stream: {e}")
                    return
                H.failure(model, e)
                last = (502, json.dumps({"error": {"message": f"upstream error: {e}"}}).encode())
                log(f"[chat] {model} 连接失败: {e},尝试下一个 ({i + 1}/{len(cands)})")
                i += 1
            finally:
                if conn:
                    conn.close()
        self._send(last[0], last[1])

    def _relay_stream(self, resp, extra):
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type", "text/event-stream"))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        self._headers_sent = True
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # 客户端断开


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler):
        self.address_family = socket.AF_INET6 if ":" in addr[0] else socket.AF_INET
        super().__init__(addr, handler)

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    threading.Thread(target=probe_loop, daemon=True).start()
    log(f"gateway listening on [{BIND}]:{PORT} -> {UPSTREAM} (FREE_ONLY={FREE_ONLY}, fallback={AUTO_FALLBACK})")
    Server((BIND, PORT), Handler).serve_forever()
PYEOF
chmod +x /usr/local/bin/antseed-free-filter.py

# 402 自动切换节点身份的看门狗脚本
cat > /usr/local/bin/antseed-rotate-identity.sh <<'SHEOF'
#!/bin/sh
# 检测到 402 (AntSeed credits 用尽) 时,轮换节点身份并重启 buyer。
# 由 antseed-free-filter.py 在 402 时后台触发。
set -u
LOCK="/tmp/antseed-rotate.lock"
IDENTITY_HEX=$(openssl rand -hex 32)
U=/etc/systemd/system/antseed-buyer.service
P=/etc/profile.d/antseed.sh

# 防并发:锁存在说明上一次切换还没完成(超过 300s 视为失效,防止残留锁永久卡死)
if [ -f "$LOCK" ]; then
    if [ "$(($(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0)))" -lt 300 ]; then
        exit 0
    fi
    rm -f "$LOCK"
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# 记录轮换日志(方便排查)
echo "$(date -Iseconds) rotate-identity -> $(echo ${IDENTITY_HEX} | dd bs=1 count=16 2>/dev/null)..." >> /var/log/antseed-rotate.log

# 1) 更新 profile.d 中的身份(保持唯一来源)
[ -f "$P" ] && sed -i "s/export ANTSEED_IDENTITY_HEX=.*/export ANTSEED_IDENTITY_HEX=${IDENTITY_HEX}/" "$P"

# 2) 更新 systemd unit 的 Environment 并重载重启 buyer
if [ -f "$U" ]; then
    sed -i 's/ANTSEED_IDENTITY_HEX=[^"]*/ANTSEED_IDENTITY_HEX='"${IDENTITY_HEX}"'/' "$U"
    systemctl daemon-reload
    systemctl restart antseed-buyer.service
fi

# 3) 等待 buyer 就绪(轮询内部 8378,最长 120s)
i=0
while [ $i -lt 120 ]; do
    if curl -s -m 2 http://127.0.0.1:8378/v1/models >/dev/null 2>&1; then
        break
    fi
    i=$((i+2))
    sleep 2
done
SHEOF
chmod +x /usr/local/bin/antseed-rotate-identity.sh


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
Environment="AUTO_ROTATE=1"
Environment="PROBE_INTERVAL=300"
Environment="FAIL_THRESHOLD=2"
Environment="BLACKLIST_SECONDS=900"
Environment="AUTO_FALLBACK=1"
Environment="MAX_ATTEMPTS=3"
ExecStart=/usr/bin/env python3 /usr/local/bin/antseed-free-filter.py
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
# IPv6 以 [..] 包裹以保证 URL 合法;若 IPv4/IPv6 都拿不到,回退 127.0.0.1,保证输出永不为空。
get_realip() {
    local ip="" ip6=""
    ip=$(curl -4 -sm 2 ip.sb) || true
    ipv6() { curl -6 -sm 2 ip.sb || true; }
    if [ -z "$ip" ]; then
        ip6=$(ipv6)
        if [ -n "$ip6" ]; then echo "[$ip6]"; else echo "127.0.0.1"; fi
    elif curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ip6=$(ipv6)
        if [ -n "$ip6" ]; then echo "[$ip6]"; else echo "127.0.0.1"; fi
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
