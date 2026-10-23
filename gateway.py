#!/usr/bin/env python3
"""Antseed Gateway —— 对外 OpenAI / Anthropic 兼容网关 (v2)

合并了第三方实现的最优部分,并修掉原版(v1)的问题:

  1. 后台探活:每 PROBE_INTERVAL 秒对每个候选发 max_tokens=1 的小请求,
     成功记 EWMA 延迟,连续 FAIL_THRESHOLD 次失败冷 BLACKLIST_SECONDS 秒
  2. 单请求多候选回退:402/404/408/409/425/429/5xx/连接失败 -> 换下一个
  3. 真流式透传:stream=true 逐包 chunked flush,不再整段缓冲
  4. 鉴权:常量时间比较;未配置 key 时默认拒绝启动(ALLOW_NO_AUTH=1 才放行)
  5. 模型别名:auto / antseed(以及空模型名)-> 当前最快的健康模型
  6. FREE_ONLY 在路由层强制:点名付费模型直接 400,不再把 402 甩给客户端
  7. /health 反映真实上游状态,/v1/health/detail 给出每个模型的明细
  8. 上游请求绕过 http_proxy;路径白名单只放行 /v1/*;请求体大小上限;并发上限
  9. 402 换身份默认关闭(AUTO_ROTATE=0);开启时经一次性 systemd unit 同步重试
 10. 兼容 Anthropic 客户端:x-api-key 也可作为入站凭证

只依赖 Python 3.7+ 标准库。
"""

import errno
import hmac
import http.client
import http.server
import json
import os
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

VERSION = "2.0.9"

if sys.version_info < (3, 7):
    sys.exit("antseed-gateway 需要 Python 3.7+，当前 %s" % sys.version.split()[0])


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _env_bool(name, default):
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


# ---------------- 配置 ----------------
UPSTREAM = os.environ.get("UPSTREAM", "http://127.0.0.1:8378").rstrip("/")
API_KEY = os.environ.get("ANTSEED_API_KEY", "").strip()
ALLOW_NO_AUTH = _env_bool("ALLOW_NO_AUTH", False)
FREE_ONLY = _env_bool("FREE_ONLY", True)
PORT = _env_int("GATEWAY_PORT", 8377)
BIND = os.environ.get("GATEWAY_BIND", "::") or "::"

PROBE_INTERVAL = _env_int("PROBE_INTERVAL", 300)
PROBE_TIMEOUT = _env_int("PROBE_TIMEOUT", 45)
PROBE_WORKERS = _env_int("PROBE_WORKERS", 4)
HEALTHY_TTL = _env_int("HEALTHY_TTL", PROBE_INTERVAL * 3)
FAIL_THRESHOLD = _env_int("FAIL_THRESHOLD", 2)
BLACKLIST_SECONDS = _env_int("BLACKLIST_SECONDS", 900)
SOFT_COOLDOWN = _env_int("SOFT_COOLDOWN", 180)   # 402/429:换个 peer 可能就好了,冷却短一些
# 402 里有一类是"押金不足"(insufficient_deposits):对端收费、我们 deposit 是 0。
# 这不是"模型坏了",冷却要短(充值或换个 $0 peer 立刻可用),而且必须给用户能看懂的文案 ——
# 否则客户端只会把它翻译成"额度已用尽",看起来像自己把免费额度用光了。
DEPOSIT_COOLDOWN = _env_int("DEPOSIT_COOLDOWN", 60)
# 回给客户端的 HTTP 状态。**默认 400 而不是 402**,原因见 DEPOSIT_HINT 下面的注释。
DEPOSIT_STATUS = _env_int("DEPOSIT_STATUS", 400)
DEPOSIT_HINT = ("对端要押金(insufficient_deposits):这个模型只挂了极少数 $0 peer,"
                "本次请求被派到了收费 peer,而本机 AntSeed 押金为 0。"
                "改用 auto 或其它免费模型;要用它就先 antseed buyer deposit <金额>")
# 为什么 400 而不是 402:很多客户端(例如 DSH)"看到 402 就显示额度用尽",而且它还会用
# 正则 insufficient[_-](quota|balance|credits) 二次判定 —— 所以既不能回 402,
# error.type 也不能写 insufficient_quota,code 里更不能出现 quota/credits 字样。
# 400 + invalid_request_error 属于"这次请求不行,原因如下",客户端会把 message 原样显示。
DEPOSIT_ETYPE = "invalid_request_error"
DEPOSIT_ECODE = "model_requires_deposit"

AUTO_FALLBACK = _env_bool("AUTO_FALLBACK", True)
# 点名具体模型时失败后是否允许换别的模型。默认 false = 和 v1 一致:
# 你点名 deepseek-v4-flash,就不该悄悄拿 glm 的答案回来。
FALLBACK_NAMED = _env_bool("FALLBACK_NAMED", False)
MAX_ATTEMPTS = max(1, _env_int("MAX_ATTEMPTS", 3))
FALLBACK_ORDER = [m.strip() for m in os.environ.get("FALLBACK_ORDER", "").split(",") if m.strip()]
STREAM_IDLE_TIMEOUT = _env_int("STREAM_IDLE_TIMEOUT", 90)
NONSTREAM_TIMEOUT = _env_int("NONSTREAM_TIMEOUT", 300)
MODELS_TTL = _env_int("MODELS_TTL", 60)

MAX_BODY = _env_int("MAX_BODY_MB", 64) * 1024 * 1024
MAX_CONCURRENCY = max(1, _env_int("MAX_CONCURRENCY", 64))
CLIENT_TIMEOUT = _env_int("CLIENT_TIMEOUT", 300)
ACCESS_LOG = _env_bool("ACCESS_LOG", True)

AUTO_ROTATE = _env_bool("AUTO_ROTATE", False)
ROTATE_UNIT = os.environ.get("ROTATE_UNIT", "antseed-rotate.service")
# 节点身份的唯一来源:v2 用 buyer.env;读不到时回退到 v1 的 systemd unit
IDENTITY_FILE = os.environ.get("IDENTITY_FILE", "/etc/antseed/buyer.env")
BUYER_UNIT = os.environ.get("BUYER_UNIT", "/etc/systemd/system/antseed-buyer.service")

REQ_TIMEOUT = dict(connect=10)
AUTO_NAMES = {"auto", "antseed", ""}

# 这些路径的请求体是带 model 字段的 JSON,统一做别名解析 + 候选回退。
# 其余 /v1/* 原样透传(音频、文件、批处理等,体不是这种结构)。
MODEL_PATHS = ("/v1/chat/completions", "/v1/completions", "/v1/embeddings")


def MODEL_PATH_LABEL(path):
    if path.startswith("/v1/messages"):
        return "messages"
    return path.rsplit("/", 1)[-1] or "proxy"
RETRYABLE = {402, 404, 408, 409, 425, 429, 500, 502, 503, 504}
# 只转发这些非鉴权头给上游;鉴权头(x-api-key / Authorization)永远不下发,
# 避免把本网关的 key 泄漏给 buyer / peer。
FWD_HEADERS = {"accept", "anthropic-version", "anthropic-beta", "user-agent",
               "openai-organization", "openai-project", "idempotency-key"}
for _extra in os.environ.get("FWD_HEADERS", "").split(","):
    if _extra.strip():
        FWD_HEADERS.add(_extra.strip().lower())

# 上游是本机 buyer,必须绕过 http_proxy/https_proxy 环境变量
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

_UP = urllib.parse.urlsplit(UPSTREAM)
UP_HOST = _UP.hostname or "127.0.0.1"
UP_PORT = _UP.port or (443 if _UP.scheme == "https" else 80)
UP_HTTPS = _UP.scheme == "https"

_STATS = {"req": 0, "ok": 0, "fail": 0, "fallback": 0, "stream": 0}
_STATS_LOCK = threading.Lock()
_CREDIT_MODELS = set()
_DEPOSIT_MODELS = set()   # 真实请求撞到"押金不足"的模型:只在 /v1/models 上标注,不删条目
_PROBE_402 = set()
_ROTATE_LOCK = threading.Lock()
_SEM = threading.BoundedSemaphore(MAX_CONCURRENCY)

if not API_KEY and not ALLOW_NO_AUTH:
    sys.exit("ANTSEED_API_KEY 未设置。对外暴露的网关必须鉴权;确需关闭请设 ALLOW_NO_AUTH=1")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def bump(key, n=1):
    with _STATS_LOCK:
        _STATS[key] = _STATS.get(key, 0) + n


def is_free(p):
    return p.get("inputUsdPerMillion", 999) == 0 and p.get("outputUsdPerMillion", 999) == 0


def is_deposit_error(detail):
    """402 的 body 是不是"押金不足"这一类"""
    if isinstance(detail, (bytes, bytearray)):
        detail = detail.decode("utf-8", "replace")
    d = (detail or "").lower()
    return ("insufficient_deposits" in d
            or "out of antseed credits" in d
            or "add funds" in d)


# ---------------- 健康状态 ----------------
class Health:
    def __init__(self):
        self.lock = threading.Lock()
        self.catalog = {}   # model_id -> 上游 /v1/models 条目
        self.state = {}     # model_id -> dict(ok_at, latency, fails, banned_until, last_error)
        self.last_probe = 0
        self.last_probe_error = None

    def _st(self, m):
        return self.state.setdefault(m, {"ok_at": 0, "latency": None, "fails": 0,
                                         "banned_until": 0, "last_error": None})

    def success(self, m, latency=None):
        now = time.time()
        with self.lock:
            s = self._st(m)
            s["ok_at"] = now
            if latency is not None:
                s["latency"] = latency if s["latency"] is None else 0.7 * s["latency"] + 0.3 * latency
            s["fails"] = 0
            s["banned_until"] = 0
            s["last_error"] = None

    def failure(self, m, err, cooldown=None):
        cool = cooldown or BLACKLIST_SECONDS
        with self.lock:
            s = self._st(m)
            s["fails"] += 1
            s["last_error"] = str(err)[:200]
            if s["fails"] >= FAIL_THRESHOLD and s["banned_until"] <= time.time():
                s["banned_until"] = time.time() + cool
                log("[ban] %s 冷却 %ss: %s" % (m, cool, s["last_error"]))

    def healthy(self):
        """按 FALLBACK_ORDER + 延迟升序返回健康模型"""
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


# ---------------- 上游 HTTP ----------------
def up_conn(timeout):
    if UP_HTTPS:
        return http.client.HTTPSConnection(UP_HOST, UP_PORT, timeout=timeout)
    return http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=timeout)


def fetch_catalog():
    """拉全量模型表;FREE_ONLY=1 时只保留存在 $0 报价 peer 的 text 模型"""
    with _OPENER.open(UPSTREAM + "/v1/models", timeout=60) as r:
        data = json.loads(r.read() or b"{}")
    cat = {}
    for m in data.get("data", []):
        if m.get("type", "text") != "text":
            continue
        if FREE_ONLY:
            allp = m.get("peers") or []
            peers = [p for p in allp if is_free(p)]
            if not peers:
                continue
            # 记住"22 个 peer 里只有 1 个 $0"这种事实:过滤后只剩免费 peer,
            # 不记下来就再也看不出"名义免费、实际大概率被派到收费 peer"。
            m = dict(m, peers=peers, _free_peers=len(peers), _peer_total=len(allp))
        mid = m.get("id")
        if mid:
            cat[mid] = m
    return cat


def _build_alias(cat):
    """别名 -> 规范 id。上游目录里每个模型带 aliases,例如 glm-5.3-flash 的别名有
    glm-5-3-flash / glm53flash / z-ai-glm-5-3-flash。之前只认 id,
    用户拿别名来调会被 FREE_ONLY 守卫当成"非免费模型"直接 400。"""
    out = {}
    for mid, m in cat.items():
        out[mid] = mid
        al = m.get("aliases")
        if isinstance(al, list):
            for a in al:
                if isinstance(a, str) and a and a not in out:
                    out[a] = mid
    return out


_CAT = {"at": 0.0, "data": {}, "err": None, "alias": {}}
_RAW = {"at": 0.0, "data": {}}          # 未过滤的完整目录,仅用于解释"为什么这个模型不可用"
_CAT_LOCK = threading.Lock()
_CAT_FETCH = threading.Lock()


def catalog(force=False):
    with _CAT_LOCK:
        fresh = _CAT["data"] and (time.time() - _CAT["at"]) < MODELS_TTL
        if fresh and not force:
            return _CAT["data"]
    with _CAT_FETCH:                       # 防止并发请求同时打上游
        with _CAT_LOCK:
            if not force and _CAT["data"] and (time.time() - _CAT["at"]) < MODELS_TTL:
                return _CAT["data"]
        try:
            cat = fetch_catalog()
        except Exception as e:
            with _CAT_LOCK:
                _CAT["err"] = str(e)[:200]
                stale = _CAT["data"]
            if stale:
                log("[models] 上游拉取失败,继续用旧缓存: %s" % e)
                return stale
            raise
        with _CAT_LOCK:
            _CAT["data"] = cat
            _CAT["at"] = time.time()
            _CAT["err"] = None
            _CAT["alias"] = _build_alias(cat)
        with H.lock:
            H.catalog = cat
        return cat


def raw_catalog(force=False):
    """上游全量目录(不按价格过滤),只在需要解释拒绝原因时用"""
    with _CAT_LOCK:
        if not force and _RAW["data"] and (time.time() - _RAW["at"]) < MODELS_TTL:
            return _RAW["data"]
    with _OPENER.open(UPSTREAM + "/v1/models", timeout=60) as r:
        data = json.loads(r.read() or b"{}")
    out = {}
    for m in data.get("data", []):
        mid = m.get("id")
        if mid:
            out[mid] = m
    with _CAT_LOCK:
        _RAW["data"] = out
        _RAW["at"] = time.time()
    return out


def alias_map():
    """别名 -> 规范 id;目录刷新后自动跟着换"""
    with _CAT_LOCK:
        if not _CAT["alias"] and _CAT["data"]:
            _CAT["alias"] = _build_alias(_CAT["data"])
        return dict(_CAT["alias"])


def canonical_model(name):
    """把用户写的模型名(可能是别名)换成目录里的规范 id;不认识就原样返回

    客户端常给模型名套一层 provider 前缀(DSH 界面上就叫 `openai/gpt-6-luna`),
    目录里的 id 本身也可能带斜杠(`inclusionai/ling-3.1-flash`),所以只在
    "整串查不到、去掉前缀能查到"时才剥前缀,不会动真正的斜杠 id。
    """
    if not isinstance(name, str) or not name or name in AUTO_NAMES:
        return name
    m = alias_map()
    hit = m.get(name) or m.get(name.lower())
    if hit:
        return hit
    if "/" in name:
        # 逐层剥:openai/gpt-6-luna -> gpt-6-luna;vendor/openai/gpt-6-luna -> openai/gpt-6-luna
        parts = name.split("/")
        for i in range(1, len(parts)):
            tail = "/".join(parts[i:])
            hit = m.get(tail) or m.get(tail.lower())
            if hit:
                return hit
    if ":" in name:                       # openai:gpt-6-luna 这种老写法
        tail = name.rsplit(":", 1)[-1]
        hit = m.get(tail) or m.get(tail.lower())
        if hit:
            return hit
    return name


def probe(model, _retry=False):
    body = json.dumps({"model": model, "max_tokens": 1, "stream": False,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(UPSTREAM + "/v1/chat/completions", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with _OPENER.open(req, timeout=PROBE_TIMEOUT) as r:
            data = json.loads(r.read() or b"{}")
        if not data.get("choices"):
            raise ValueError("no choices in response")
        _PROBE_402.discard(model)
        H.success(model, time.time() - t0)
        return True
    except urllib.error.HTTPError as e:
        try:
            detail = (e.read() or b"")[:160].decode("utf-8", "replace").strip()
        except Exception:
            detail = ""
        # 押金不足重试没意义(换个 peer 也是同一笔账),而且它不代表模型不可用
        if e.code == 402 and is_deposit_error(detail):
            _DEPOSIT_MODELS.add(model)
            H.failure(model, "HTTP 402 " + DEPOSIT_HINT, cooldown=DEPOSIT_COOLDOWN)
            return False
        # 402(本轮没额度)/429(对端并发满)都是"换一个 peer 可能就好",重试一次再判死刑
        if e.code in (402, 429) and not _retry:
            time.sleep(2)
            return probe(model, True)
        H.failure(model, "HTTP %s: %s" % (e.code, detail or "(空响应)"),
                  cooldown=SOFT_COOLDOWN if e.code in (402, 429) else None)
        if e.code == 402:
            _PROBE_402.add(model)
    except Exception as e:
        H.failure(model, e)
    return False


def seed_models():
    """首轮探活还没跑完时的临时候选:先 FALLBACK_ORDER,再按目录名补。

    没有这层兜底,服务刚起来的那 30~50 秒里 healthy 是空的,
    model=auto 会直接 503 —— 装完立刻调一下 API 的人只会看到"不可用"。
    """
    try:
        cat = catalog()
    except Exception:
        cat = {}
    # 兜底优先用 FALLBACK_ORDER,但只保留目录里真实存在的:名单是写死在配置里的,
    # 上游下架某个模型后它就不该再被当成候选。
    out = [m for m in FALLBACK_ORDER if not cat or m in cat]
    if cat:
        out += sorted(m for m in cat if m not in out)
    return out


def probe_loop():
    while True:
        try:
            cat = catalog(force=True)
            todo = [m for m in cat if not H.banned(m)]
            if FALLBACK_ORDER:                     # 首轮先探兜底名单里的模型
                rank = {m: i for i, m in enumerate(FALLBACK_ORDER)}
                todo.sort(key=lambda m: (rank.get(m, len(rank)), m))
            with ThreadPoolExecutor(PROBE_WORKERS) as ex:
                results = list(ex.map(probe, todo))
                if AUTO_ROTATE and _PROBE_402 and todo and not any(results):
                    log("[probe] 候选全部 402,轮换节点身份后重探一轮")
                    rotate_sync()
                    results = list(ex.map(probe, sorted(_PROBE_402)))
            H.last_probe = time.time()
            H.last_probe_error = None
            log("[probe] 候选 %d,本轮探测 %d,通过 %d,健康: %s"
                % (len(cat), len(todo), sum(results), ", ".join(H.healthy()) or "无"))
        except Exception as e:
            H.last_probe_error = str(e)[:200]
            log("[probe] 拉取模型列表失败: %s" % e)
        time.sleep(max(10, PROBE_INTERVAL))


# ---------------- 402 换身份(默认关闭) ----------------
def current_identity():
    for path in (IDENTITY_FILE, BUYER_UNIT):
        try:
            with open(path) as f:
                for line in f:
                    if line.startswith("ANTSEED_IDENTITY_HEX=") or "ANTSEED_IDENTITY_HEX=" in line:
                        return line.split("ANTSEED_IDENTITY_HEX=", 1)[1].strip().strip('"')
        except OSError:
            continue
    return ""


def rotate_sync():
    """同步触发一次性 systemd unit 换身份,等 buyer 就绪;身份确实变化才清状态"""
    if not AUTO_ROTATE:
        return False
    with _ROTATE_LOCK:
        before = current_identity()
        try:
            subprocess.run(["systemctl", "start", "--no-block", ROTATE_UNIT],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=30, check=False)
        except Exception as e:
            log("[rotate] 触发 %s 失败: %s" % (ROTATE_UNIT, e))
            return False
        deadline = time.time() + 240
        while time.time() < deadline:
            try:
                out = subprocess.run(["systemctl", "is-active", ROTATE_UNIT],
                                     capture_output=True, text=True, timeout=10)
                if out.stdout.strip() not in ("activating", "active"):
                    break
            except Exception:
                break
            time.sleep(2)
        for _ in range(90):
            try:
                with _OPENER.open(UPSTREAM + "/v1/models", timeout=5) as r:
                    r.read()
                break
            except Exception:
                time.sleep(2)
        after = current_identity()
        if after and after != before:
            _CREDIT_MODELS.clear()
            H.reset_all()
            log("[rotate] identity %s -> %s" % (before[:8], after[:8]))
            return True
        log("[rotate] 身份未变化(或无法读取),放弃本轮轮换")
        return False


# ---------------- HTTP 服务 ----------------
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "antseed-gateway/" + VERSION
    # 客户端读超时,防止慢连接长期占用线程
    timeout = CLIENT_TIMEOUT

    # --- 工具 ---
    def log_message(self, fmt, *args):
        if not ACCESS_LOG:
            return
        log("%s %s" % (self.address_string(), fmt % args))

    def _auth_ok(self):
        if not API_KEY:
            return ALLOW_NO_AUTH
        got = self.headers.get("Authorization", "").strip()
        if not got:
            key = self.headers.get("x-api-key", "").strip()
            if key:
                got = "Bearer " + key
        return hmac.compare_digest(got.encode(), ("Bearer " + API_KEY).encode())

    def _send(self, status, body, ctype="application/json", extra=None, log_it=True):
        if not isinstance(body, (bytes, bytearray)):
            body = bytes(body)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        if log_it and ACCESS_LOG:
            bump("req")
            bump("ok" if status < 400 else "fail")
            log("%s %s -> %d (%dB)" % (self.command, self.path.split("?")[0], status, len(body)))

    def _json(self, status, obj, extra=None):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode(), extra=extra)

    def _err(self, status, msg, etype="gateway_error", extra=None):
        self._json(status, {"error": {"message": msg, "type": etype}}, extra=extra)

    def _deposit_reply(self):
        """押金不足的统一回包:状态码/type/code 都按"客户端会照实显示 message"来选"""
        return self._json(DEPOSIT_STATUS,
                          {"error": {"message": DEPOSIT_HINT,
                                     "type": DEPOSIT_ETYPE,
                                     "code": DEPOSIT_ECODE,
                                     "param": "deposits"}})

    def _read_body(self):
        raw = self.headers.get("Content-Length")
        if raw is None:
            return b""
        try:
            n = int(raw)
        except (TypeError, ValueError):
            raise ValueError("invalid Content-Length")
        if n < 0:
            raise ValueError("invalid Content-Length")
        if n > MAX_BODY:
            raise OverflowError("request body too large")
        chunks = []
        left = n
        while left > 0:
            buf = self.rfile.read(min(left, 65536))
            if not buf:
                break
            chunks.append(buf)
            left -= len(buf)
        return b"".join(chunks)

    # --- 路由 ---
    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/health":
            return self._health()
        if path == "/v1/health/detail":
            if not self._auth_ok():
                return self._err(401, "invalid api key", "authentication_error")
            return self._json(200, H.snapshot())
        if path == "/v1/models":
            if not self._auth_ok():
                return self._err(401, "invalid api key", "authentication_error")
            return self._models()
        if not path.startswith("/v1/"):
            return self._err(404, "not found: " + path)
        return self._proxy(b"")

    def do_HEAD(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/health":
            return self._health()
        if not path.startswith("/v1/"):
            return self._err(404, "not found: " + path)
        return self._proxy(b"")

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if not path.startswith("/v1/"):
            return self._err(404, "not found: " + path)
        if not self._auth_ok():
            return self._err(401, "invalid api key", "authentication_error")
        try:
            body = self._read_body()
        except OverflowError:
            return self._err(413, "request body larger than %dMB" % (MAX_BODY // 1024 // 1024))
        except ValueError as e:
            return self._err(400, str(e))
        if path in MODEL_PATHS or path.startswith("/v1/messages"):
            return self._model_request(body, label=MODEL_PATH_LABEL(path))
        return self._proxy(body)

    # --- 端点 ---
    def _health(self):
        healthy = H.healthy()
        with _STATS_LOCK:
            stats = dict(_STATS)
        return self._json(200, {
            "ok": bool(healthy) or not H.last_probe,
            "warming_up": not H.last_probe,
            "will_route_to": (healthy[:1] or seed_models()[:1] or [None])[0],
            "version": VERSION,
            "upstream": UPSTREAM,
            "free_only": FREE_ONLY,
            "auto_rotate": AUTO_ROTATE,
            "healthy": healthy,
            "last_probe_ago_s": int(time.time() - H.last_probe) if H.last_probe else None,
            "last_probe_error": H.last_probe_error,
            "needs_deposit": sorted(_DEPOSIT_MODELS),
            "stats": stats,
        })

    def _models(self):
        """列出全部"免费目录"里的模型(和 v1 的过滤规则一致),再用 x_* 字段标健康度。

        v2.0.4 之前这里只列探活通过的模型,于是 deepseek-v4-flash 这种
        "有免费 peer 但当前 402" 的模型会整条消失 —— 这就是"模型变少了"的原因。
        列表归列表,路由归路由:auto 只落在健康模型上,但别的模型不该从目录里被删掉。
        """
        try:
            cat = catalog()
        except Exception as e:
            return self._err(502, "cannot fetch model catalog: %s" % e, "upstream_error")
        healthy = H.healthy()
        snap = H.snapshot()
        rank = {m: i for i, m in enumerate(healthy)}
        ids = sorted(cat, key=lambda m: (rank.get(m, len(rank)), m))
        routes_to = (healthy or seed_models() or [None])[0]
        data = [
            {"id": "auto", "object": "model", "owned_by": "gateway", "x_routes_to": routes_to},
            {"id": "antseed", "object": "model", "owned_by": "gateway",
             "x_alias_of": "auto", "x_routes_to": routes_to},
        ]
        for m in ids:
            item = dict(cat.get(m, {"id": m}))
            item["object"] = "model"
            st = snap.get(m, {})
            item["x_healthy"] = bool(st.get("healthy"))
            item["x_latency_s"] = st.get("latency_s")
            if st.get("banned_for_s"):
                item["x_cooldown_for_s"] = st["banned_for_s"]
            if st.get("last_error"):
                item["x_last_error"] = st["last_error"][:120]
            free_n = item.pop("_free_peers", None)
            tot_n = item.pop("_peer_total", None)
            if free_n is not None and tot_n:
                item["x_free_peers"] = "%d/%d" % (free_n, tot_n)
            else:
                peers = item.get("peers") or []
                if peers:
                    item["x_free_peers"] = "%d/%d" % (sum(1 for p in peers if is_free(p)), len(peers))
            if m in _DEPOSIT_MODELS:
                item["x_needs_deposit"] = True
            data.append(item)
        return self._json(200, {"object": "list", "data": data})

    # --- 候选选择 ---
    def _candidates(self, requested):
        healthy = H.healthy()
        if requested in AUTO_NAMES:
            pool = healthy or seed_models()        # 首轮探活期间也不空转
            first = pool[:1]
            if not AUTO_FALLBACK:
                return first
            rest = [m for m in pool if m not in first]
            return (first + rest)[:MAX_ATTEMPTS]
        if H.banned(requested) or requested in _CREDIT_MODELS:
            first = []
        else:
            first = [requested]
        if not AUTO_FALLBACK or not FALLBACK_NAMED:
            return first                     # 点名就给点名的,失败照实报错
        rest = [m for m in healthy if m not in first]
        return (first + rest)[:MAX_ATTEMPTS]

    def _free_only_guard(self, requested):
        """FREE_ONLY=1 时,点名非免费模型直接 400,不要让它打到上游换一个 402 回来"""
        if not FREE_ONLY or requested in AUTO_NAMES:
            return None
        try:
            cat = catalog()
        except Exception:
            return None            # 拿不到目录就不拦,交给上游判断
        if not cat or requested in cat or requested in alias_map():   # 别名映射的 key 含 id 与别名
            return None
        return ("model %r not in free catalog%s. use model=auto, or one of: %s"
                % (requested, self._why_not_free(requested), ", ".join(sorted(cat)[:8])))

    def _why_not_free(self, name):
        """把"为什么这个模型用不了"说成一句人话:上游没有 / 有但不再免费"""
        try:
            raw = raw_catalog()
        except Exception:
            return ""
        m = raw.get(name) or raw.get(canonical_model(name))
        if not m:
            return " (upstream has no such model: removed or renamed)"
        ps = m.get("peers") or []
        if not ps:
            return " (no peer currently serves it)"
        prices = [(p.get("inputUsdPerMillion"), p.get("outputUsdPerMillion")) for p in ps]
        lo = min(prices, key=lambda x: (x[0] if x[0] is not None else 1e9))
        fmt = lambda v: "?" if v is None else ("%g" % v)
        return " (upstream %d peers, cheapest $%s/$%s per M, no $0 peer)" % (
            len(ps), fmt(lo[0]), fmt(lo[1]))

    # --- 普通代理(非 chat/completions,含 Anthropic /v1/messages) ---
    def _proxy(self, body):
        if not _SEM.acquire(blocking=False):
            return self._err(503, "gateway busy, retry shortly", "overloaded",
                             extra={"Retry-After": "2"})
        conn = None
        try:
            hdrs = self._up_headers()
            timeout = STREAM_IDLE_TIMEOUT if self._wants_stream() else NONSTREAM_TIMEOUT
            conn = up_conn(timeout)
            conn.request(self.command, self.path, body=body if body else None, headers=hdrs)
            resp = conn.getresponse()
            if self._is_stream_resp(resp) and resp.status < 400:
                self._relay_stream(resp)
                return
            data = resp.read()
            self._send(resp.status, data,
                       resp.getheader("Content-Type", "application/json"))
        except (socket.timeout, TimeoutError, ConnectionError,
                http.client.HTTPException, OSError) as e:
            self._err(502, "upstream error: %s" % e, "upstream_error",
                      extra={"Retry-After": "5"})
        finally:
            if conn:
                conn.close()
            _SEM.release()

    # --- 带 model 的 JSON 端点:别名解析 + 候选回退 ---
    def _model_request(self, raw, label="chat"):
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._err(400, "invalid JSON body", "invalid_request_error")
        if not isinstance(payload, dict):
            return self._err(400, "body must be a JSON object", "invalid_request_error")

        requested = payload.get("model", "")
        if not isinstance(requested, str):
            return self._err(400, "model must be a string", "invalid_request_error")
        canon = canonical_model(requested)      # glm-5-3-flash -> glm-5.3-flash
        if canon != requested:
            requested = canon
            payload["model"] = canon
        guard = self._free_only_guard(requested)
        if guard:
            return self._err(400, guard, "invalid_request_error")

        stream = bool(payload.get("stream"))
        cands = self._candidates(requested)
        if not cands:
            if requested in _DEPOSIT_MODELS:
                # 探活已经踩到押金,请求还没发出去:直接说清楚是钱的问题,别报 503
                return self._deposit_reply()
            return self._err(503, "no healthy model available right now; check /health",
                             "unavailable", extra={"Retry-After": "10"})
        if not _SEM.acquire(blocking=False):
            return self._err(503, "gateway busy, retry shortly", "overloaded",
                             extra={"Retry-After": "2"})
        try:
            self._chat_attempts(payload, cands, stream, label)
        finally:
            _SEM.release()

    def _chat_attempts(self, payload, cands, stream, label="chat"):
        self._headers_sent = False
        rotated = False
        deposit_seen = False
        i = 0
        last = (502, b'{"error":{"message":"all attempts failed","type":"upstream_error"}}')
        while i < len(cands):
            model = cands[i]
            payload["model"] = model
            body = json.dumps(payload).encode()
            t0 = time.time()
            conn = None
            try:
                conn = up_conn(STREAM_IDLE_TIMEOUT if stream else NONSTREAM_TIMEOUT)
                conn.request("POST", self.path, body=body, headers=self._up_headers(stream))
                resp = conn.getresponse()

                if resp.status == 402 and AUTO_ROTATE and not rotated and model not in _CREDIT_MODELS:
                    resp.read()
                    rotated = True
                    log("[%s] %s -> 402,轮换身份后重试同一模型" % (label, model))
                    if rotate_sync():
                        continue
                    _CREDIT_MODELS.add(model)
                    i += 1
                    continue

                if resp.status >= 400:
                    err_body = resp.read() or b"{}"
                    last = (resp.status, err_body)
                    if resp.status == 402 and is_deposit_error(err_body):
                        _DEPOSIT_MODELS.add(model)
                        deposit_seen = True
                        H.failure(model, "HTTP 402 " + DEPOSIT_HINT, cooldown=DEPOSIT_COOLDOWN)
                        log("[%s] %s -> 402 押金不足(冷却 %ss),换下一个 (%d/%d)"
                            % (label, model, DEPOSIT_COOLDOWN, i + 1, len(cands)))
                        bump("fallback")
                        i += 1
                        continue
                    if resp.status == 402:
                        _CREDIT_MODELS.add(model)
                    if resp.status in RETRYABLE:
                        H.failure(model, "HTTP %d" % resp.status)
                        log("[%s] %s -> %d,换下一个 (%d/%d)" % (label, model, resp.status, i + 1, len(cands)))
                        bump("fallback")
                        i += 1
                        continue
                    return self._send(resp.status, err_body,
                                      resp.getheader("Content-Type", "application/json"))

                extra = {"X-Antseed-Model": model, "X-Antseed-Attempt": str(i + 1)}
                if i > 0:
                    extra["X-Antseed-Fallback"] = "1"
                sse = stream or self._is_stream_resp(resp)
                if sse:
                    bump("stream")
                    self._relay_stream(resp, extra)
                    H.success(model, None)
                else:
                    data = resp.read()
                    self._send(resp.status, data,
                               resp.getheader("Content-Type", "application/json"), extra)
                    H.success(model, time.time() - t0)
                return
            except (socket.timeout, TimeoutError, ConnectionError,
                    http.client.HTTPException, OSError) as e:
                if getattr(self, "_headers_sent", False):
                    H.failure(model, "mid-stream: %s" % e)
                    log("[%s] %s 流中断: %s" % (label, model, e))
                    return
                H.failure(model, e)
                bump("fallback")
                last = (502, json.dumps({"error": {"message": "upstream error: %s" % e,
                                                   "type": "upstream_error"}}).encode())
                log("[%s] %s 连接失败: %s,换下一个 (%d/%d)" % (label, model, e, i + 1, len(cands)))
                i += 1
            finally:
                if conn:
                    conn.close()

        status, err_body = last
        if deposit_seen:
            # 比上游那句 "out of AntSeed credits ... run buyer deposit" 更直白,也避免被客户端
            # 二次翻译成"你今天额度用尽"
            return self._deposit_reply()
        if status == 402:
            self._err(503, "node credits exhausted for all candidates; retry later or use another model",
                      "insufficient_quota", extra={"Retry-After": "30"})
        elif status in RETRYABLE:
            self._err(503, "all candidate models failed (last: HTTP %d)" % status,
                      "unavailable", extra={"Retry-After": "15"})
        else:
            self._send(status, err_body)

    # --- 头 / 流 ---
    def _up_headers(self, stream=False):
        hdrs = {}
        for k, v in self.headers.items():
            if k.lower() in FWD_HEADERS:
                hdrs[k] = v
        hdrs["Content-Type"] = self.headers.get("Content-Type", "application/json")
        hdrs["Accept"] = "text/event-stream" if stream else "application/json"
        return hdrs

    def _wants_stream(self):
        return self.headers.get("Accept", "").startswith("text/event-stream")

    @staticmethod
    def _is_stream_resp(resp):
        ctype = (resp.getheader("Content-Type") or "").lower()
        return ctype.startswith("text/event-stream") or \
            (resp.getheader("Transfer-Encoding") or "").lower() == "chunked"

    def _relay_stream(self, resp, extra=None):
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type", "text/event-stream"))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")     # 给 nginx 反代看
        for k, v in (extra or {}).items():
            self.send_header(k, v)

        http10 = getattr(self, "request_version", "HTTP/1.1") == "HTTP/1.0"
        if http10:
            self.send_header("Connection", "close")
            self.close_connection = True
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self._headers_sent = True

        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                if http10:
                    self.wfile.write(chunk)
                else:
                    self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            if not http10:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except (socket.timeout, TimeoutError) as e:
            log("[stream] 上游空闲超时: %s" % e)
            self.close_connection = True
        finally:
            with _STATS_LOCK:
                _STATS["req"] = _STATS.get("req", 0) + 1
            if ACCESS_LOG:
                log("POST %s -> %d (stream)" % (self.path.split("?")[0], resp.status))


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128

    def __init__(self, addr, handler):
        self.address_family = socket.AF_INET6 if ":" in addr[0] else socket.AF_INET
        super().__init__(addr, handler)

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except OSError:
                pass
        super().server_bind()


def _listen(bind, port, handler):
    """绑定监听。返回 (server, 实际使用的地址)。

    两类常见失败在这里被翻译成人话,而不是甩一个 traceback 让 systemd 反复重启:
      EADDRINUSE     端口被别的进程占了(最常见:v1 残留的 buyer 或另一份网关)
      EAFNOSUPPORT   该地址族不可用(例如系统关了 IPv6),自动退到另一个族
    """
    order = [bind]
    if bind in ("::", ""):
        order.append("0.0.0.0")
    elif bind == "0.0.0.0":
        order.append("::")
    last = None
    for addr in order:
        try:
            return Server((addr, port), handler), addr
        except OSError as e:
            last = e
            if e.errno == errno.EAFNOSUPPORT and addr != order[-1]:
                log("监听 [%s]:%d 不可用(%s),改试 [%s]" % (addr, port, e.strerror, order[-1]))
                continue
            break
    e = last
    if e is not None and e.errno == errno.EADDRINUSE:
        log("无法监听 [%s]:%d —— 端口已被占用。"
            "排查: ss -ltnp | grep ':%d'   (常见占用者: v1 残留的 buyer 或另一份网关)"
            % (bind, port, port))
    elif e is not None and e.errno == errno.EACCES:
        log("无法监听 [%s]:%d —— 权限不足(1024 以下端口需要 root 或 CAP_NET_BIND_SERVICE)" % (bind, port))
    else:
        log("无法监听 [%s]:%d —— %s" % (bind, port, e))
    raise SystemExit(1)


def main():
    threading.Thread(target=probe_loop, daemon=True).start()
    srv, bind_used = _listen(BIND, PORT, Handler)

    def _stop(signum, frame):
        log("收到信号 %s,准备退出" % signum)
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    log("gateway v%s listening on [%s]:%d -> %s (FREE_ONLY=%s, fallback=%s, auto_rotate=%s)"
        % (VERSION, bind_used, PORT, UPSTREAM, FREE_ONLY, AUTO_FALLBACK, AUTO_ROTATE))
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
        log("gateway stopped")


if __name__ == "__main__":
    main()
