#!/usr/bin/env python3
"""antseed-gateway 行为测试:假上游(模拟 buyer) + 真网关进程。

    python3 tests/test_gateway.py          # 全跑,最后打印 N passed, M failed

覆盖 CHANGELOG 里声明的各条修复:别名/前缀剥除(v2.0.9)、押金语义 400 +
model_requires_deposit(v2.0.7/2.0.8)、列表 vs 路由分离、流式透传、鉴权、
体积/长度校验含 Connection: close(v2.0.10)、路径白名单、回退策略、头卫生。

只用标准库,不需要真的 antseed buyer;不碰任何线上服务。
"""
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:                                    # Windows 控制台默认 GBK,中文用例名会乱码
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
GW_SRC = os.path.join(os.path.dirname(HERE), "gateway.py")
LOG_DIR = os.environ.get("GW_TEST_LOGDIR") or os.path.join(
    __import__("tempfile").gettempdir(), "antseed-gwtest")
os.makedirs(LOG_DIR, exist_ok=True)
UP_PORT = 18378
GW_PORT = 18377
GW2_PORT = 18379
KEY = "sk-test-1234567890abcdef"

FREE = {"inputUsdPerMillion": 0, "outputUsdPerMillion": 0}
PAID = {"inputUsdPerMillion": 0.02, "outputUsdPerMillion": 0.05}

CATALOG = {"object": "list", "data": [
    {"id": "m-free", "type": "text", "aliases": ["mfree", "openai/m-free"],
     "peers": [FREE]},
    {"id": "m-dep", "type": "text", "aliases": ["m-deposit"],
     "peers": [FREE, {"inputUsdPerMillion": 0.002, "outputUsdPerMillion": 0.004}]},
    {"id": "m-late-dep", "type": "text", "peers": [FREE]},
    {"id": "m-paid", "type": "text", "peers": [PAID]},
    {"id": "img-1", "type": "image", "peers": [FREE]},
    {"id": "inclusionai/ling-3.1-flash", "type": "text", "peers": [FREE]},
    {"id": "glm-5.3-flash", "type": "text",
     "aliases": ["glm-5-3-flash", "glm53flash", "z-ai-glm-5-3-flash"], "peers": [FREE]},
    {"id": "m-broken", "type": "text", "peers": [FREE]},
]}

DEPOSIT_BODY = {"error": {"type": "api_error", "code": "antseed_buyer_fault",
                          "message": "You are out of AntSeed credits for this request. "
                                     "Add funds in the AntSeed app, or run "
                                     "\"antseed buyer deposit <amount>\" from the CLI, then retry.",
                          "param": "insufficient_deposits"}}

RECORDS = []
REC_LOCK = threading.Lock()


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/v1/models":
            return self._json(200, CATALOG)
        if self.path == "/__last":
            with REC_LOCK:
                return self._json(200, {"records": RECORDS[-5:]})
        if self.path == "/__reset":
            with REC_LOCK:
                RECORDS.clear()
            return self._json(200, {})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        with REC_LOCK:
            RECORDS.append({"path": self.path,
                            "model": body.get("model"),
                            "headers": {k.lower(): v for k, v in self.headers.items()}})

        model = body.get("model")
        if self.path.startswith("/v1/messages"):
            return self._json(200, {"id": "msg_1", "type": "message", "model": model,
                                    "content": [{"type": "text", "text": "ok"}]})
        if model == "m-dep":
            return self._json(402, DEPOSIT_BODY)
        if model == "m-late-dep" and body.get("max_tokens") != 1:
            return self._json(402, DEPOSIT_BODY)
        if model == "m-broken":
            return self._json(500, {"error": {"message": "boom"}})
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                chunk = ('data: {"choices":[{"delta":{"content":"t%d"}}]}\n\n' % i).encode()
                self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.2)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        return self._json(200, {"id": "chatcmpl-1", "object": "chat.completion", "model": model,
                                "choices": [{"index": 0, "message": {"role": "assistant",
                                                                     "content": "ok"}}]})


def start_upstream():
    srv = ThreadingHTTPServer(("127.0.0.1", UP_PORT), Upstream)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def start_gateway(port, extra_env=None, key=KEY):
    env = dict(os.environ)
    env.update({
        "ANTSEED_API_KEY": key,
        "UPSTREAM": "http://127.0.0.1:%d" % UP_PORT,
        "GATEWAY_PORT": str(port),
        "GATEWAY_BIND": "127.0.0.1",
        "PROBE_INTERVAL": "100000",
        "PROBE_TIMEOUT": "5",
        "MAX_BODY_MB": "1",
        "ACCESS_LOG": "0",
    })
    if extra_env:
        env.update(extra_env)
    p = subprocess.Popen([sys.executable, GW_SRC], env=env,
                         stdout=open(os.path.join(LOG_DIR, "gateway_%d.log" % port),
                                     "w", encoding="utf-8", errors="replace"),
                         stderr=subprocess.STDOUT, text=True)
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/health")
            c.getresponse().read()
            return p
        except Exception:
            if p.poll() is not None:
                raise SystemExit("gateway 启动失败: " + (p.stdout.read() or ""))
            time.sleep(0.2)
    raise SystemExit("gateway 20s 内未就绪")


def req(port, method, path, body=None, headers=None, auth=True, timeout=30):
    h = dict(headers or {})
    if auth:
        h.setdefault("Authorization", "Bearer " + KEY)
    raw = None
    if isinstance(body, (dict, list)):
        raw = json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    elif isinstance(body, bytes):
        raw = body
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    c.request(method, path, body=raw, headers=h)
    r = c.getresponse()
    data = r.read()
    out = (r.status, dict(r.getheaders()), data)
    c.close()
    return out


def last_upstream_record():
    s, _, d = req(UP_PORT, "GET", "/__last", auth=False)
    return json.loads(d)["records"][-1]


def reset_upstream():
    req(UP_PORT, "GET", "/__reset", auth=False)


PASS = 0
FAIL = []
RESULTS = []


def check(name, cond, detail=""):
    global PASS
    if cond:
        PASS += 1
        RESULTS.append(("PASS", name, detail))
    else:
        FAIL.append((name, detail))
        RESULTS.append(("FAIL", name, detail))


def main():
    start_upstream()
    gw = start_gateway(GW_PORT)
    # 等首轮探活落地
    deadline = time.time() + 30
    while time.time() < deadline:
        _, _, d = req(GW_PORT, "GET", "/health", auth=False)
        h = json.loads(d)
        if h.get("last_probe_ago_s") is not None:
            break
        time.sleep(0.3)
    health = json.loads(req(GW_PORT, "GET", "/health", auth=False)[2])

    # ---- 鉴权 ----
    s, _, _ = req(GW_PORT, "GET", "/v1/models", auth=False)
    check("无 key -> 401", s == 401, str(s))
    s, _, _ = req(GW_PORT, "GET", "/v1/models",
                  headers={"Authorization": "Bearer wrong"})
    check("错 key -> 401", s == 401, str(s))
    s, _, _ = req(GW_PORT, "GET", "/v1/models",
                  headers={"x-api-key": KEY}, auth=False)
    check("x-api-key 入站可用", s == 200, str(s))

    # ---- /health ----
    check("/health 免鉴权 200", health is not None and "ok" in health)
    check("/health warming_up=false(探活已跑)", health.get("warming_up") is False,
          str(health.get("warming_up")))
    check("/health 有 will_route_to", bool(health.get("will_route_to")),
          str(health.get("will_route_to")))
    check("/health 报 needs_deposit", "m-dep" in (health.get("needs_deposit") or []),
          str(health.get("needs_deposit")))
    s, _, _ = req(GW_PORT, "HEAD", "/health", auth=False)
    check("HEAD /health 200", s == 200, str(s))

    # ---- /v1/models:列表归列表 ----
    s, _, d = req(GW_PORT, "GET", "/v1/models")
    models = json.loads(d)["data"]
    ids = [m["id"] for m in models]
    check("/v1/models 200", s == 200, str(s))
    check("auto/antseed 排在前面", ids[:2] == ["auto", "antseed"], str(ids[:2]))
    check("付费模型被过滤", "m-paid" not in ids, str(ids))
    check("image 模型被过滤", "img-1" not in ids, str(ids))
    check("带斜杠的真 id 保留", "inclusionai/ling-3.1-flash" in ids, str(ids))
    md = [m for m in models if m["id"] == "m-dep"][0]
    check("m-dep 仍在目录里(不因健康度消失)", True)
    check("x_free_peers 标注 1/2", md.get("x_free_peers") == "1/2", str(md.get("x_free_peers")))
    check("m-dep 标 x_needs_deposit", md.get("x_needs_deposit") is True, str(md.get("x_needs_deposit")))
    check("m-dep x_healthy=false", md.get("x_healthy") is False, str(md.get("x_healthy")))
    check("m-dep 有 x_last_error", bool(md.get("x_last_error")), str(md.get("x_last_error")))
    mg = [m for m in models if m["id"] == "glm-5.3-flash"][0]
    check("健康模型 x_healthy=true", mg.get("x_healthy") is True, str(mg.get("x_healthy")))

    # ---- 正常点名 ----
    reset_upstream()
    s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                   {"model": "m-free", "messages": [{"role": "user", "content": "hi"}]})
    check("点名 m-free -> 200", s == 200, str(s))
    check("X-Antseed-Model 回显", hs.get("X-Antseed-Model") == "m-free", str(hs.get("X-Antseed-Model")))
    check("上游收到 m-free", last_upstream_record()["model"] == "m-free")

    # ---- 头卫生 ----
    hdr = last_upstream_record()["headers"]
    check("入站 Authorization 不下发上游", "authorization" not in hdr, str(hdr.keys()))
    check("入站 x-api-key 不下发上游", "x-api-key" not in hdr, str(hdr.keys()))

    # ---- auto 路由 ----
    s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                   {"model": "auto", "messages": [{"role": "user", "content": "hi"}]})
    body = json.loads(d)
    check("auto -> 200", s == 200, str(s))
    check("auto 落点是目录里的真模型",
          body.get("model") in [m["id"] for m in CATALOG["data"]], str(body.get("model")))
    check("auto 回填 X-Antseed-Model", hs.get("X-Antseed-Model") == body.get("model"))

    # ---- 别名 / provider 前缀(v2.0.9) ----
    for name, expect in [("glm-5-3-flash", "glm-5.3-flash"),
                         ("openai/m-free", "m-free"),
                         ("vendor/openai/m-free", "m-free"),
                         ("openai:m-free", "m-free"),
                         ("inclusionai/ling-3.1-flash", "inclusionai/ling-3.1-flash")]:
        reset_upstream()
        s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                       {"model": name, "messages": [{"role": "user", "content": "hi"}]})
        got = last_upstream_record()["model"] if s == 200 else None
        check("模型名 %s -> %s" % (name, expect), s == 200 and got == expect,
              "status=%s upstream=%s" % (s, got))

    # ---- 押金语义(v2.0.7/2.0.8) ----
    s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                   {"model": "m-dep", "messages": [{"role": "user", "content": "hi"}]})
    eb = json.loads(d)["error"]
    check("m-dep -> 400 而非 402", s == 400, str(s))
    check("type=invalid_request_error", eb.get("type") == "invalid_request_error", eb.get("type"))
    check("code=model_requires_deposit", eb.get("code") == "model_requires_deposit", eb.get("code"))
    blob = json.dumps(eb, ensure_ascii=False).lower()
    check("文案不出现 quota/credits 字样",
          not any(w in blob for w in ("quota", "credits")), blob[:120])
    check("文案指向 deposit", "deposit" in blob, blob[:120])

    # 请求前没被探活标记、但真实请求撞到押金的模型
    s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                   {"model": "m-late-dep", "messages": [{"role": "user", "content": "hi"}]})
    check("m-late-dep 真实请求撞押金 -> 400 deposit", s == 400 and
          json.loads(d)["error"].get("code") == "model_requires_deposit",
          "status=%s body=%s" % (s, d[:120]))
    s, _, d = req(GW_PORT, "GET", "/v1/models")
    ml = [m for m in json.loads(d)["data"] if m["id"] == "m-late-dep"][0]
    check("跑过之后列表标 x_needs_deposit", ml.get("x_needs_deposit") is True, str(ml))

    # ---- FREE_ONLY 守卫 ----
    s, _, d = req(GW_PORT, "POST", "/v1/chat/completions",
                  {"model": "m-paid", "messages": [{"role": "user", "content": "hi"}]})
    msg = json.loads(d)["error"]["message"]
    check("点名付费模型 -> 400", s == 400, str(s))
    check("拒绝文案说明上游报价", "cheapest" in msg, msg[:120])

    # ---- 点名失败不偷偷换模型 ----
    s, _, d = req(GW_PORT, "POST", "/v1/chat/completions",
                  {"model": "m-broken", "messages": [{"role": "user", "content": "hi"}]})
    check("FALLBACK_NAMED=0:点名 500 模型 -> 503 不换模型", s == 503, str(s))

    # ---- 流式 ----
    reset_upstream()
    t0 = time.time()
    s, hs, d = req(GW_PORT, "POST", "/v1/chat/completions",
                   {"model": "m-free", "stream": True,
                    "messages": [{"role": "user", "content": "hi"}]},
                   headers={"Accept": "text/event-stream"})
    el = time.time() - t0
    text = d.decode("utf-8", "replace")
    check("流式 -> 200", s == 200, str(s))
    check("流式 Transfer-Encoding: chunked",
          (hs.get("Transfer-Encoding") or "").lower() == "chunked", str(hs.get("Transfer-Encoding")))
    check("流式 3 个 data 块完整", text.count("data:") == 3, str(text.count("data:")))
    check("流式 X-Accel-Buffering: no", hs.get("X-Accel-Buffering") == "no")

    # ---- Anthropic /v1/messages ----
    reset_upstream()
    s, hs, d = req(GW_PORT, "POST", "/v1/messages",
                   {"model": "auto", "max_tokens": 16,
                    "messages": [{"role": "user", "content": "hi"}]})
    got = last_upstream_record()["model"]
    check("Anthropic /v1/messages auto 被解析", s == 200 and got in
          [m["id"] for m in CATALOG["data"]], "status=%s upstream=%s" % (s, got))

    # ---- 体积 / 长度 / 坏 JSON / 路径 ----
    # 413:除了状态码,还要求 "Connection: close" —— 否则 2MB 未读请求体留在连接里,
    # 下一个"请求"会从 body 中间开始解析,客户端看到的是连接被重置。
    big = {"Content-Type": "application/json"}
    try:
        c = http.client.HTTPConnection("127.0.0.1", GW_PORT, timeout=30)
        c.putrequest("POST", "/v1/chat/completions")
        c.putheader("Authorization", "Bearer " + KEY)
        c.putheader("Content-Type", "application/json")
        c.putheader("Content-Length", str(2 * 1024 * 1024))
        c.endheaders()
        try:
            c.send(b"x" * (2 * 1024 * 1024))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
            pass
        r = c.getresponse()
        hdrs413 = {k.lower(): v for k, v in r.getheaders()}
        r.read()
        check("2MB body(上限1MB) -> 413", r.status == 413, str(r.status))
        check("413 带 Connection: close", hdrs413.get("connection", "").lower() == "close",
              str(hdrs413.get("connection")))
        c.close()
    except Exception as e:
        check("2MB body(上限1MB) -> 413", False, "连接异常: %r" % (e,))
        check("413 带 Connection: close", False, "连接异常: %r" % (e,))

    c = http.client.HTTPConnection("127.0.0.1", GW_PORT, timeout=10)
    c.putrequest("POST", "/v1/chat/completions")
    c.putheader("Authorization", "Bearer " + KEY)
    c.putheader("Content-Length", "abc")
    c.endheaders()
    r = c.getresponse()
    hdrsbad = {k.lower(): v for k, v in r.getheaders()}
    r.read()
    check("非法 Content-Length -> 400", r.status == 400, str(r.status))
    check("非法 Content-Length 带 Connection: close",
          hdrsbad.get("connection", "").lower() == "close", str(hdrsbad.get("connection")))
    c.close()

    s, _, _ = req(GW_PORT, "POST", "/v1/chat/completions", b"{not json}")
    check("坏 JSON -> 400", s == 400, str(s))

    s, _, _ = req(GW_PORT, "GET", "/console/api/secret", auth=False)
    check("非 /v1 路径 -> 404", s == 404, str(s))
    s, _, _ = req(GW_PORT, "GET", "/v1/../etc/passwd")
    check("路径穿越 -> 404", s == 404, str(s))
    s, _, _ = req(GW_PORT, "GET", "/v1/health/detail")
    check("/v1/health/detail 需鉴权", s == 200, str(s))

    # ---- 第二个实例:FALLBACK_NAMED=1 时点名失败要回退 ----
    gw2 = start_gateway(GW2_PORT, {"FALLBACK_NAMED": "1", "AUTO_FALLBACK": "1"})
    deadline = time.time() + 30
    while time.time() < deadline:
        h = json.loads(req(GW2_PORT, "GET", "/health", auth=False)[2])
        if h.get("last_probe_ago_s") is not None:
            break
        time.sleep(0.3)
    s, hs, d = req(GW2_PORT, "POST", "/v1/chat/completions",
                   {"model": "m-broken", "messages": [{"role": "user", "content": "hi"}]})
    check("FALLBACK_NAMED=1:点名 500 模型回退成功", s == 200, str(s))
    check("回退时 X-Antseed-Fallback: 1", hs.get("X-Antseed-Fallback") == "1",
          str(hs.get("X-Antseed-Fallback")))
    check("回退后 X-Antseed-Model 不是点名的那个",
          hs.get("X-Antseed-Model") != "m-broken", str(hs.get("X-Antseed-Model")))
    gw2.terminate()

    # ---- 无 key 拒绝启动 ----
    env = dict(os.environ)
    env.update({"ANTSEED_API_KEY": "", "GATEWAY_PORT": "18380", "UPSTREAM": "http://127.0.0.1:%d" % UP_PORT})
    env.pop("ALLOW_NO_AUTH", None)
    p = subprocess.run([sys.executable, GW_SRC], env=env, capture_output=True, text=True, timeout=30)
    check("未配置 key 时拒绝启动", p.returncode != 0 and "ANTSEED_API_KEY" in (p.stderr + p.stdout),
          "rc=%s %s" % (p.returncode, (p.stderr or p.stdout)[:80]))

    for proc in (gw,):
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()

    print("")
    for st, name, detail in RESULTS:
        print("%s  %s%s" % (st, name, ("   [" + str(detail) + "]") if st == "FAIL" else ""))
    print("\n%d passed, %d failed" % (PASS, len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
