#!/usr/bin/env bash
# Antseed Gateway 一键安装器 + 管理菜单(版本见下方 VERSION)
#
# 用法:
#   apikey=your_key bash install.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh)
#   bash install.sh                        # 交互菜单(安装/升级/卸载/更新CLI/状态/日志)
#   bash install.sh --dry-run              # 只打印将要做什么,不改系统
#   bash install.sh upgrade                # 只替换网关程序/unit + 重启 + 自检
#   bash install.sh uninstall              # 停服务、删程序,保留 /etc/antseed 与节点身份
#   bash install.sh uninstall --purge      # 连配置和节点身份一起删
#   bash install.sh update-cli             # 官方 @antseed/cli 有新版就更新 /usr/bin/antseed
#   bash install.sh status                 # 服务/网关/模型/端口 一览
#   bash install.sh logs --follow          # 实时日志
#
# 环境变量:
#   apikey / API_KEY        网关 API key(不传则自动生成)
#   FREE_ONLY               1=只路由免费模型(默认) 0=全部模型
#   GATEWAY_PORT            对外端口,默认 8377
#   GATEWAY_BIND            监听地址,默认 "::"(双栈);只给本机用设 127.0.0.1
#   BUYER_PORT              buyer 端口,默认 8378
#   CLI_VERSION             @antseed/cli 版本,默认 latest(生产环境建议锁版本)
#   FALLBACK_ORDER          回退优先级,逗号分隔
#   FALLBACK_NAMED          1=点名模型失败后换别的模型(默认 0 = 照实报错)
#   AUTO_ROTATE             1=402 时自动换节点身份(默认 0,有风险,见 README)
#   FORCE_ROTATE=1          重装时强制换节点身份(默认复用已有身份)
#   FORCE_INSTALL=1         即使已装也重装 @antseed/cli
#   SYSTEM_NODE=0           不探测系统 Node,强制用内置 Node
#   SKIP_NODE=1             不下载 Node(要求系统 Node >= 24)
#   PUBLIC_HOST             跳过公网 IP 探测,安装完成时直接展示这个域名/IP
#   NODE_VERSION            Node 版本,默认 v24.21.0

set -Eeuo pipefail
umask 022

VERSION="2.0.10"
PROG="antseed-gateway"

GATEWAY_PY="/usr/local/bin/antseed-gateway.py"
ROTATE_SH="/usr/local/bin/antseed-rotate-identity.sh"
CONF_DIR="/etc/antseed"
GW_ENV="$CONF_DIR/gateway.env"
BUYER_ENV="$CONF_DIR/buyer.env"
GW_UNIT="/etc/systemd/system/antseed-gateway.service"
BUYER_UNIT="/etc/systemd/system/antseed-buyer.service"
ROTATE_UNIT="/etc/systemd/system/antseed-rotate.service"

GW_PORT="${GATEWAY_PORT:-8377}"
GW_BIND="${GATEWAY_BIND:-::}"
BUYER_PORT="${BUYER_PORT:-8378}"
FREE_ONLY="${FREE_ONLY:-1}"
CLI_VERSION="${CLI_VERSION:-latest}"
NODE_VERSION="${NODE_VERSION:-v24.21.0}"
NODE_DIR="/usr/local/node-${NODE_VERSION}"
FALLBACK_ORDER="${FALLBACK_ORDER:-deepseek-v4-flash,glm-5.3-flash,openai-gpt-oss-120b}"
AUTO_ROTATE="${AUTO_ROTATE:-0}"

# 重装时只更新"显式指定"的项,其余保留 gateway.env 里的手改
GIVEN_KEY=0; GIVEN_FREE_ONLY=0; GIVEN_PORT=0; GIVEN_BIND=0
if [ -n "${API_KEY:-}${apikey:-}" ]; then GIVEN_KEY=1; fi
if [ -n "${FREE_ONLY:-}" ]; then GIVEN_FREE_ONLY=1; fi
if [ -n "${GATEWAY_PORT:-}" ]; then GIVEN_PORT=1; fi
if [ -n "${GATEWAY_BIND:-}" ]; then GIVEN_BIND=1; fi
PURGE=0
DRY_RUN=0
ACTION="install"
CHECK_ONLY=0        # update-cli --check:只报告有没有新版
ASSUME_YES=0        # update-cli --yes:不确认直接装
LOG_FOLLOW=0        # logs --follow:实时跟随
LOG_LINES=60

RED='' GREEN='' YELLOW='' NC=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
fi

log()  { printf '%s[%s]%s %s\n' "$GREEN" "$PROG" "$NC" "$*"; }
warn() { printf '%s[%s]%s %s\n' "$YELLOW" "$PROG" "$NC" "$*"; }
die()  { printf '%s[%s]%s %s\n' "$RED" "$PROG" "$NC" "$*" >&2; exit 1; }
on_err() { printf '%s[%s]%s 中断于第 %s 行 (exit %s);排错: bash -x %s\n' \
            "$RED" "$PROG" "$NC" "${1:-?}" "${2:-?}" "${0##*/}" >&2; }
trap 'on_err "$LINENO" "$?"' ERR

usage() {
    cat <<'USAGE'
Antseed Gateway 一键安装器

用法:
  bash install.sh                         交互菜单(安装/升级/卸载/更新 CLI/状态/日志/配置)
  apikey=KEY bash install.sh install      直接安装 / 重装(非交互)
  bash install.sh --dry-run               只打印将要做什么
  bash install.sh upgrade                 只替换网关程序与 unit,保留配置与身份
  bash install.sh uninstall [--purge]     卸载(--purge 连配置和节点身份一起删)
  bash install.sh update-cli [--check]    检测官方 @antseed/cli,有新版才更新 /usr/bin/antseed
  bash install.sh status                  服务 / 网关 / 模型 / 端口 一览
  bash install.sh logs [--follow]         查看日志(--follow 实时跟随)
  bash install.sh config                  交互改配置(API key、端口、FREE_ONLY…)
  bash install.sh --force-rotate          重装时强制换节点身份
  bash install.sh --help                  显示本帮助

配置里想跳过菜单(脚本/CI 用): NO_MENU=1 bash install.sh

常用环境变量:
  apikey=KEY          网关 API key(不传自动生成)
  FREE_ONLY=0         允许路由到付费模型(默认 1=仅免费)
  GATEWAY_BIND=::     监听地址(默认双栈;127.0.0.1 表示只本机)
  GATEWAY_PORT=8377   对外端口
  CLI_VERSION=latest  @antseed/cli 版本(生产建议锁版本)
  FALLBACK_ORDER=a,b  回退优先级
  AUTO_ROTATE=1       402 时自动换节点身份(默认关闭)
  FORCE_ROTATE=1      重装时强制换节点身份
  PUBLIC_HOST=host    跳过公网 IP 探测
USAGE
}

# run: 真正的变更命令(输出可见);run_q: 静默;干跑时都只打印
run() {
    if [ "$DRY_RUN" = "1" ]; then log "would run: $*"; else "$@"; fi
}
run_q() {
    if [ "$DRY_RUN" = "1" ]; then log "would run: $*"; else "$@" >/dev/null 2>&1; fi
}

# 从 stdin 落盘:write_file <path> [mode]
write_file() {
    local path="$1" mode="${2:-0644}"
    if [ "$DRY_RUN" = "1" ]; then
        local n; n="$(cat | wc -c)"
        log "would write $path ($mode, ${n}B)"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    chmod "$mode" "$path"
}

download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        run curl -fsSL --retry 3 --connect-timeout 10 --max-time 900 -o "$dest" "$url"
    else
        run wget -q -O "$dest" --timeout=30 --tries=3 "$url"
    fi
}

# ============================================================================
#  运行期管理命令:菜单 / 状态 / 日志 / 改配置 / 更新官方 CLI
#  这几项不参与安装流程,也可单独执行(bash install.sh status 等)。
# ============================================================================
CLI_PKG="@antseed/cli"

# 只改指定的一行:存在就替换,不存在就追加
env_set() {
    local f="$1" k="$2" v="$3"
    if [ "$DRY_RUN" = "1" ]; then
        log "would set $k in $f"
        return 0
    fi
    if grep -q "^${k}=" "$f" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
}
read_env() {
    [ -f "$2" ] || return 0
    sed -n "s/^${1}=//p" "$2" 2>/dev/null | head -1 || true
}

# 脚本自身路径:菜单要靠它 re-exec 自己执行子动作
#
# 关键陷阱:一键安装是 `bash <(curl -fsSL .../install.sh)`,此时 $0 是 /dev/fd/63。
# 那个 fd 是**一次性管道**,而且和正在读取执行本脚本的 bash 共用同一个 file
# offset —— 谁再读它一次,外层 bash 的续读就会从文件中间开始,函数定义全丢,
# 随后报出一屏 `log: command not found`(行号还是文件真实行号)。
# 所以管道场景下**绝不 cat / 读 $0**,只标记"自己是管道",菜单要重执行时
# 再从固定 URL 现取一份干净的副本。
SELF_PATH=""
SELF_URL="${INSTALL_URL:-https://raw.githubusercontent.com/pingmike2/antseed-gateway/main/install.sh}"
SELF_IS_PIPE=0
_self_src="${BASH_SOURCE[0]:-$0}"
case "$_self_src" in
    /dev/fd/*|/proc/*/fd/*|/dev/stdin|-) SELF_IS_PIPE=1 ;;
esac
# 管道模式下记住 bash 用来读脚本的 fd,退出前排空它 —— 否则 `bash <(curl ...)`
# 提前退出(菜单选 0)时 curl 还在写管道,会吐一行
# `curl: (23) Failure writing output to destination`,看着像故障,其实只是 EPIPE。
SELF_PIPE_FD=""
if [ "$SELF_IS_PIPE" = "1" ]; then
    case "$_self_src" in
        /dev/fd/*|/proc/*/fd/*) SELF_PIPE_FD="${_self_src##*/}" ;;
    esac
    # bash 读脚本用的那个 fd 带 CLOEXEC,exec 出去的子进程继承不到。
    # 先复制成 fd 9(shell 打开的 fd 不带 CLOEXEC),退出时才能排空管道。
    if [ -n "$SELF_PIPE_FD" ]; then
        eval "exec 9<&$SELF_PIPE_FD" 2>/dev/null || SELF_PIPE_FD=""
    fi
fi
if [ "$SELF_IS_PIPE" = "0" ] && [ -n "$_self_src" ] && [ -r "$_self_src" ] && [ ! -c "$_self_src" ]; then
    _sp_dir="$(cd "$(dirname "$_self_src")" 2>/dev/null && pwd)" || _sp_dir=""
    [ -n "$_sp_dir" ] && SELF_PATH="$_sp_dir/$(basename "$_self_src")"
    unset _sp_dir
fi
unset _self_src

# menu_self: 给菜单拿一个"能被重新 bash 执行"的脚本路径
#   1) 本来就是文件方式运行 -> 用它自己
#   2) 管道方式(<(curl ...) / curl | bash) -> 从 SELF_URL 现取一份到临时文件
menu_self() {
    if [ -n "$SELF_PATH" ] && [ -s "$SELF_PATH" ]; then
        printf '%s' "$SELF_PATH"
        return 0
    fi
    if [ -n "${SELF_CACHE:-}" ] && [ -s "$SELF_CACHE" ]; then
        printf '%s' "$SELF_CACHE"
        return 0
    fi
    # 注意:不能放 TMPDIR_INSTALL —— 那个目录会在退出时被 trap 整个删掉,
    # 而菜单还要拿这个副本去执行子动作(卸载/升级),必须先于清理存在。
    SELF_CACHE="/tmp/.antseed-self-$$.sh"
    rm -f "$SELF_CACHE" 2>/dev/null
    printf '  准备执行副本(最多 20s)...' >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 --connect-timeout 8 "$SELF_URL" -o "$SELF_CACHE" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=20 --tries=1 -O "$SELF_CACHE" "$SELF_URL" 2>/dev/null || true
    fi
    printf '\n' >&2
    if [ -s "$SELF_CACHE" ] && bash -n "$SELF_CACHE" 2>/dev/null; then
        chmod 0700 "$SELF_CACHE"
        trap 'rm -f "$SELF_CACHE"' EXIT
        printf '%s' "$SELF_CACHE"
        return 0
    fi
    rm -f "$SELF_CACHE" 2>/dev/null
    SELF_CACHE=""
    return 1
}

TMPDIR_INSTALL="${TMPDIR_INSTALL:-/tmp}"

# node / npm / antseed 三件套:独立运行时也要能找到
toolchain_probe() {
    NODE_BIN="${NODE_BIN:-}"; NPM_BIN="${NPM_BIN:-}"
    NODE_PREFIX="${NODE_PREFIX:-}"; ANTSEED_BIN="${ANTSEED_BIN:-}"
    if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
        if command -v node >/dev/null 2>&1; then
            NODE_BIN="$(command -v node)"
            NPM_BIN="${NPM_BIN:-$(command -v npm 2>/dev/null || true)}"
        elif [ -x "$NODE_DIR/bin/node" ]; then
            NODE_BIN="$NODE_DIR/bin/node"; NPM_BIN="$NPM_BIN$([ -n "${NPM_BIN:-}" ] || echo "$NODE_DIR/bin/npm")"
            NPM_BIN="$NODE_DIR/bin/npm"
        else
            NODE_BIN=""
        fi
    fi
    if [ -z "$NODE_PREFIX" ] && [ -n "$NPM_BIN" ]; then
        NODE_PREFIX="$("$NPM_BIN" prefix -g 2>/dev/null || echo /usr/local)"
    fi
    if [ -z "$ANTSEED_BIN" ] || [ ! -e "$ANTSEED_BIN" ]; then
        ANTSEED_BIN="$(command -v antseed 2>/dev/null || true)"
    fi
    [ -n "$ANTSEED_BIN" ] || ANTSEED_BIN="${NODE_PREFIX:+$NODE_PREFIX/bin/antseed}"
    ANTSEED_BIN="${ANTSEED_BIN:-/usr/bin/antseed}"
}

cli_current() {   # 本机已装的 @antseed/cli 版本;读不到就返回空
    toolchain_probe
    { [ -n "$NODE_BIN" ] && [ -e "$ANTSEED_BIN" ]; } || return 0
    "$NODE_BIN" "$ANTSEED_BIN" --version 2>/dev/null | tr -d '[:space:]' | tail -1 || true
}

cli_latest() {    # 官方 registry 上的最新版本;查不到(离线/无 npm)就返回空
    toolchain_probe
    [ -n "$NPM_BIN" ] || return 0
    if command -v timeout >/dev/null 2>&1; then
        { timeout 30 "$NPM_BIN" view "$CLI_PKG" version 2>/dev/null || true; } | tr -d '[:space:]' | tail -1
    else
        { "$NPM_BIN" view "$CLI_PKG" version 2>/dev/null || true; } | tr -d '[:space:]' | tail -1
    fi
}

version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ]; }

m_wait_health() {
    local i
    for i in $(seq 1 30); do
        curl -fsS -m 2 "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

m_wait_buyer() {
    local i
    [ "$DRY_RUN" = "1" ] && return 0
    for i in $(seq 1 45); do
        curl -fsS -m 3 "http://127.0.0.1:$BUYER_PORT/v1/models" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# ---------------- 4) 更新官方 CLI ----------------
# /usr/bin/antseed 是 npm 全局包 @antseed/cli 的符号链接,官方二进制就该用 npm 更新
do_update_cli() {
    toolchain_probe
    echo ""
    if [ -z "$NODE_BIN" ]; then
        warn "找不到 node:还没装或不在 PATH 里,先跑一次安装"
        return 1
    fi
    local cur lat link
    cur="$(cli_current)"
    log "当前 CLI: ${cur:-读不到}  (${ANTSEED_BIN})"
    link="$(readlink -f "$ANTSEED_BIN" 2>/dev/null || true)"
    case "$link" in
        *node_modules/@antseed/cli/*)
            log "确认是官方 npm 包: $link" ;;
        *)
            if [ -n "$NPM_BIN" ] && \
               { timeout 20 "$NPM_BIN" ls -g --depth=0 2>/dev/null || true; } | grep -q '@antseed/cli@'; then
                log "确认是官方 npm 全局包: $( { timeout 20 "$NPM_BIN" ls -g --depth=0 2>/dev/null || true; } \
                        | grep -o '@antseed/cli@[^ ]*' | head -1)"
            elif [ -z "$link" ]; then
                warn "读不到 $ANTSEED_BIN 的真实路径(可能还没装)"
            else
                warn "它不指向 @antseed/cli 包目录: $link —— 仍按 npm 官方包处理"
            fi ;;
    esac
    printf '  查询 npm registry 上的最新版本...'
    lat="$(cli_latest)"
    if [ -z "$lat" ]; then
        echo ""
        warn "查询不到最新版本(npm 不可用或没网),保持现状不动"
        return 3
    fi
    printf ' %s\n\n' "$lat"

    if [ -n "$cur" ] && ! version_gt "$lat" "$cur"; then
        log "已是最新($cur),不做任何改动"
        return 0
    fi
    log "发现新版本: ${cur:-?} -> $lat"
    if [ "$CHECK_ONLY" = "1" ]; then
        log "(--check 模式:只报告不安装)"
        return 1
    fi
    if [ "$ASSUME_YES" != "1" ]; then
        local a
        read -r -p "  现在更新 $ANTSEED_BIN ? [Y/n] " a || a="y"
        case "$a" in [nN]*) log "已跳过,保持现状"; return 0 ;; esac
    fi
    log "npm install -g ${CLI_PKG}@${lat} ..."
    # shellcheck disable=SC2086  # ${NPM_ALLOW:-} 为空时要展开成 0 个参数
    run "$NPM_BIN" install -g "${CLI_PKG}@${lat}" --no-audit --no-fund ${NPM_ALLOW:-}
    if [ "$DRY_RUN" = "1" ]; then
        log "would restart antseed-buyer"
        return 0
    fi
    [ -e "$ANTSEED_BIN" ] || die "更新后 $ANTSEED_BIN 不见了,回滚: npm install -g ${CLI_PKG}@${cur}"
    log "更新后版本: $(cli_current)"

    # buyer 是常驻进程,换完 CLI 要重启它才生效;网关会自己重新拉目录(≤MODELS_TTL)
    if systemctl cat antseed-buyer.service >/dev/null 2>&1; then
        log "重启 antseed-buyer 让新 CLI 生效..."
        run systemctl restart antseed-buyer.service || true
        if m_wait_buyer; then
            log "buyer 已就绪(端口 $BUYER_PORT)"
        else
            warn "buyer 90s 内未就绪: journalctl -u antseed-buyer -n 60 --no-pager"
        fi
    fi
    log "完成。网关会在 ${MODELS_TTL:-60}s 内自动刷新模型目录,无需重启"
    return 0
}

menu_gw_version() {   # 从已安装的 gateway.py 里读版本;没装就返回空
    [ -f "$GATEWAY_PY" ] || return 0
    sed -n 's/^VERSION *= *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$GATEWAY_PY" 2>/dev/null | head -1 || true
}

# ---------------- 5) 状态与自检 ----------------
do_status() {
    local py="${PYBIN:-python3}" port key u state
    port="$(read_env GATEWAY_PORT "$GW_ENV" 2>/dev/null || true)"; port="${port:-$GW_PORT}"
    key="$(read_env ANTSEED_API_KEY "$GW_ENV" 2>/dev/null || true)"; key="${key:-${API_KEY:-}}"
    echo ""
    echo "===================== 服务 ====================="
    for u in antseed-gateway antseed-buyer antseed-rotate; do
        state="$(systemctl is-active "$u.service" 2>/dev/null || true)"
        printf '  %-20s %s\n' "$u" "${state:-未安装}"
    done
    printf '  %-20s %s\n' "网关程序" "$(menu_gw_version)"
    printf '  %-20s %s\n' "官方 CLI" "$(cli_current)"
    echo "  监听:"
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | grep -qE ":(${port}|${BUYER_PORT})\b"; then
            ss -ltnp 2>/dev/null | grep -E ":(${port}|${BUYER_PORT})\b" | sed 's/^/    /' || true
        else
            echo "    端口 ${port}/${BUYER_PORT} 上没有监听"
        fi
    fi
    echo "===================== 配置 ====================="
    if [ -f "$GW_ENV" ]; then
        for k in FREE_ONLY FALLBACK_NAMED AUTO_ROTATE GATEWAY_BIND GATEWAY_PORT \
                 PROBE_INTERVAL MODELS_TTL BLACKLIST_SECONDS SOFT_COOLDOWN DEPOSIT_COOLDOWN \
                 DEPOSIT_STATUS \
                 MAX_ATTEMPTS FALLBACK_ORDER; do
            state="$(read_env "$k" "$GW_ENV" 2>/dev/null || true)"
            [ -n "$state" ] && printf '  %-17s %s\n' "$k" "$state"
        done
        echo "  (文件 $GW_ENV)"
    else
        echo "  $GW_ENV 不存在(未安装或已 purge)"
    fi
    if [ -z "$key" ]; then
        warn "读不到 API key,跳过 HTTP 自检"
        echo ""
        return 0
    fi
    "$py" - "$port" "$key" <<'STATUS_PY'
import json, sys, urllib.error, urllib.request
port, key = sys.argv[1], sys.argv[2]

def get(path, auth=False):
    req = urllib.request.Request(
        "http://127.0.0.1:%s%s" % (port, path),
        headers={"Authorization": "Bearer " + key} if auth else {})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(body).get("error", {}).get("message") or body
        except Exception:
            pass
        raise RuntimeError("HTTP %s: %s" % (e.code, body[:160]))
    except Exception as e:
        raise RuntimeError(str(e))

def head(title):
    print("===================== %s =====================" % title)

head("网关")
try:
    h = get("/health")
    print("  版本            %s   %s" % (h.get("version"), "ok" if h.get("ok") else "未就绪"))
    print("  warming_up      %s" % h.get("warming_up"))
    print("  auto 落点       %s" % (h.get("will_route_to") or "-"))
    ago = h.get("last_probe_ago_s")
    print("  上次探活        %s" % ("%ss 前" % ago if ago is not None else "-"))
except Exception as e:
    print("  /health 无响应: %s" % e)

head("模型")
try:
    data = get("/v1/models", True).get("data") or []
except Exception as e:
    print("  /v1/models 读不到: %s" % e)
    data = []
if data:
    healthy = [m.get("id") for m in data if m.get("x_healthy")]
    print("  条目            %d 个(其中健康 %d)" % (len(data), len(healthy)))
    print("  auto ->         %s" % next((m.get("x_routes_to") for m in data if m.get("id") == "auto"), "-"))
    bad = [m for m in data if m.get("id") not in ("auto", "antseed") and not m.get("x_healthy")]
    if bad:
        print("  暂不可用:")
        for m in bad[:10]:
            print("    %-32s %s" % (m.get("id"), (m.get("x_last_error") or "未探活")[:70]))
STATUS_PY
    echo ""
}

# ---------------- 6) 日志 ----------------
do_logs() {
    command -v journalctl >/dev/null 2>&1 || die "没有 journalctl,无法查看日志"
    local n="${LOG_LINES:-60}"
    if [ "$LOG_FOLLOW" = "1" ]; then
        log "实时日志(Ctrl-C 退出)..."
        exec journalctl -u antseed-gateway -u antseed-buyer -n "$n" -f --no-pager
    fi
    journalctl -u antseed-gateway -u antseed-buyer -n "$n" --no-pager
    echo ""
    log "实时跟随: bash $0 logs --follow"
}

# ---------------- 7) 改配置 ----------------
do_config() {
    [ -f "$GW_ENV" ] || die "找不到 $GW_ENV,先跑一次安装"
    local k v
    while :; do
        echo ""
        echo "==================== 修改配置 ===================="
        printf '  1) API Key        %s\n' "$(read_env ANTSEED_API_KEY "$GW_ENV" | sed 's/\(.\{10\}\).*/\1…/')"
        printf '  2) FREE_ONLY      %s      (1=只用免费模型, 0=允许付费)\n' "$(read_env FREE_ONLY "$GW_ENV")"
        printf '  3) 监听地址       %s\n' "$(read_env GATEWAY_BIND "$GW_ENV")"
        printf '  4) 对外端口       %s\n' "$(read_env GATEWAY_PORT "$GW_ENV")"
        printf '  5) FALLBACK_NAMED %s      (1=点名模型失败后换模型)\n' "$(read_env FALLBACK_NAMED "$GW_ENV")"
        printf '  6) AUTO_ROTATE    %s      (1=402 时换节点身份)\n' "$(read_env AUTO_ROTATE "$GW_ENV")"
        printf '  7) 探活周期       %ss  / 目录缓存 %ss\n' "$(read_env PROBE_INTERVAL "$GW_ENV")" "$(read_env MODELS_TTL "$GW_ENV")"
        echo "  0) 返回"
        local c; read -r -p "  选择 [0-7]: " c || return 0
        case "$c" in
            1) read -r -p "  新 API Key(回车不改): " v || true
               [ -n "$v" ] && { env_set "$GW_ENV" ANTSEED_API_KEY "$v"; log "已更新 API Key"; } ;;
            2) read -r -p "  FREE_ONLY [0/1](回车不改): " v || true
               case "$v" in 0|1) env_set "$GW_ENV" FREE_ONLY "$v"; log "已设为 $v" ;; "") ;; *) warn "只接受 0 或 1" ;; esac ;;
            3) read -r -p "  监听地址(:: / 0.0.0.0 / 127.0.0.1): " v || true
               [ -n "$v" ] && { env_set "$GW_ENV" GATEWAY_BIND "$v"; log "已设为 $v"; } ;;
            4) read -r -p "  端口: " v || true
               case "$v" in ''|*[!0-9]*) warn "只接受数字" ;; *) env_set "$GW_ENV" GATEWAY_PORT "$v"; log "已设为 $v" ;; esac ;;
            5) read -r -p "  FALLBACK_NAMED [0/1]: " v || true
               case "$v" in 0|1) env_set "$GW_ENV" FALLBACK_NAMED "$v"; log "已设为 $v" ;; "") ;; *) warn "只接受 0 或 1" ;; esac ;;
            6) read -r -p "  AUTO_ROTATE [0/1]: " v || true
               case "$v" in 0|1) env_set "$GW_ENV" AUTO_ROTATE "$v"; log "已设为 $v" ;; "") ;; *) warn "只接受 0 或 1" ;; esac ;;
            7) read -r -p "  探活周期秒(建议 120-600): " v || true
               case "$v" in ''|*[!0-9]*) warn "只接受数字" ;; *) env_set "$GW_ENV" PROBE_INTERVAL "$v"; log "已设为 $v" ;; esac
               read -r -p "  目录缓存秒(建议 30-300): " v || true
               case "$v" in ''|*[!0-9]*) ;; *) env_set "$GW_ENV" MODELS_TTL "$v"; log "已设为 $v" ;; esac ;;
            0|"") return 0 ;;
            *) warn "无效选择" ;;
        esac
        run systemctl restart antseed-gateway.service || true
        if m_wait_health; then log "网关已重启并恢复"; else warn "重启后 30s 内 /health 未就绪: journalctl -u antseed-gateway -n 60"; fi
    done
}

# ---------------- 菜单 ----------------
menu_state() {
    local st; st="$(systemctl is-active antseed-gateway.service 2>/dev/null || true)"
    printf '%s' "${st:-未安装}"
}
# 菜单读输入统一走真实终端:bash <(curl ...) 会把 stdin 顶成 /dev/fd/63,
# 直接 read 会读到脚本自己的字节流(或者 EOF),菜单当场退出。
# 注意:必须用「写入全局变量」的形态,不能 $(menu_ask ...) 取返回值。
# 命令替换会开子 shell,fd 3(/dev/tty)在子 shell 里默认不可读,
# 菜单就会卡在 read 上直到超时。所以统一用 menu_ask VAR "提示" [默认值]。
menu_ask() {   # menu_ask <目标变量名> <提示> [默认值]
    local _var="$1" _p="$2" _d="${3-}" _v=""
    printf '%s' "$_p" >&2
    if [ "${MENU_TTY:-0}" = "1" ]; then
        IFS= read -r _v <&3 || _v=""
    else
        IFS= read -r _v || _v=""
    fi
    [ -n "$_v" ] || _v="$_d"
    printf -v "$_var" '%s' "$_v"
}

do_menu() {
    local c a key gwv
    while :; do
        gwv="$(menu_gw_version)"
        echo ""
        echo "=================================================="
        echo "   Antseed Gateway 管理菜单      安装器 v${VERSION}"
        echo "--------------------------------------------------"
        printf '   网关 %-6s %-9s  CLI %-9s 端口 %s\n' \
            "${gwv:-未装}" "$(menu_state)" "$(cli_current || echo '未装')" \
            "$(read_env GATEWAY_PORT "$GW_ENV" 2>/dev/null || echo "$GW_PORT")"
        echo "--------------------------------------------------"
        echo "  1) 安装 / 重装网关        (保留已有配置与节点身份)"
        echo "  2) 升级网关程序           (只换程序与 unit,不动配置)"
        echo "  3) 卸载网关               (可选连配置与身份一起删)"
        echo "  4) 更新官方 CLI           (检测到新版才装 @antseed/cli)"
        echo "  5) 状态与自检             (/health、模型、端口)"
        echo "  6) 查看日志               (最近 60 行 / 实时跟随)"
        echo "  7) 修改配置               (API key、端口、FREE_ONLY…)"
        echo "  0) 退出"
        echo "=================================================="
        menu_ask c "  选择 [0-7]: "
        case "$c" in
            1)
                _ms="$(menu_self)" || die "拿不到可重执行的脚本副本(离线?)。请在本地已下载的 install.sh 上跑菜单。"
                menu_ask key "  API Key(留空=沿用已有/自动生成): "
                echo ""
                if [ -n "$key" ]; then
                    exec env NO_MENU=1 INSTALL_URL="$SELF_URL" bash "$_ms" --key="$key"
                else
                    exec env NO_MENU=1 INSTALL_URL="$SELF_URL" bash "$_ms"
                fi
                ;;
            2)
                _ms="$(menu_self)" || die "拿不到可重执行的脚本副本(离线?)。请用: bash install.sh upgrade"
                echo ""
                NO_MENU=1 bash "$_ms" upgrade || warn "升级返回非零"
                ;;
            3)
                _ms="$(menu_self)" || die "拿不到可重执行的脚本副本(离线?)。请用: bash install.sh uninstall [--purge]"
                menu_ask a "  连 /etc/antseed 配置与节点身份一起删? [y/N] "
                case "$a" in
                    [yY]*) NO_MENU=1 bash "$_ms" uninstall --purge || warn "卸载返回非零" ;;
                    *)     NO_MENU=1 bash "$_ms" uninstall || warn "卸载返回非零" ;;
                esac
                ;;
            4)
                _ms="$(menu_self)" || die "拿不到可重执行的脚本副本(离线?)。请用: bash install.sh update-cli"
                # 有更新就装,没有就保持现状
                NO_MENU=1 ASSUME_YES=${MENU_ASSUME_YES:-1} bash "$_ms" update-cli || true
                ;;
            5) do_status ;;
            6)
                menu_ask a "  1=最近 60 行  2=实时跟随  [1]: " 1
                case "$a" in
                    2) LOG_FOLLOW=1 do_logs ;;
                    *) do_logs ;;
                esac
                ;;
            7) do_config ;;
            0|q|Q|"") log "退出"; return 0 ;;
            *) warn "无效选择: $c" ;;
        esac
        printf '\n  按回车返回菜单...' >&2
        if [ "${MENU_TTY:-0}" = "1" ]; then IFS= read -r _ <&3 || return 0; else IFS= read -r _ || return 0; fi
    done
}

# ---------------- 参数 ----------------
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        --purge) PURGE=1 ;;
        --force|--reinstall) FORCE_INSTALL=1 ;;
        --force-rotate) FORCE_ROTATE=1 ;;
        --key=*) API_KEY="${arg#*=}"; GIVEN_KEY=1 ;;
        --apikey=*) API_KEY="${arg#*=}"; GIVEN_KEY=1 ;;
        --apikey) API_KEY="${2-}"; GIVEN_KEY=1; shift ;;
        --port=*) GW_PORT="${arg#*=}"; GIVEN_PORT=1 ;;
        --public-host=*) PUBLIC_HOST="${arg#*=}" ;;
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --follow) LOG_FOLLOW=1 ;;
        --lines=*) LOG_LINES="${arg#*=}" ;;
        menu) ACTION=menu ;;
        install|upgrade|uninstall|remove|status|logs|config) ACTION="${arg/remove/uninstall}" ;;
        update-cli|update|check-cli)
            ACTION=update-cli
            [ "$arg" = "check-cli" ] && CHECK_ONLY=1 ;;
        *) usage >&2; die "未知参数: $arg" ;;
    esac
done

[ "$DRY_RUN" = "1" ] && warn "DRY-RUN: 下面只显示将要执行的操作"

# ---------------- 平台闸门(Windows / macOS / WSL) ----------------
# 这个安装器写 systemd unit、动 /etc、用 systemd 管进程 —— 只能在 Linux 上跑。
# 与其让人在 Git Bash / PowerShell 里跑到一半炸掉,不如开头就说清楚该怎么办。
OS_KERNEL="$(uname -s 2>/dev/null || echo unknown)"
case "$OS_KERNEL" in
    Linux)
        # WSL 能跑,但 systemd 默认是关的,给了提示再继续
        if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
            if [ ! -d /run/systemd/system ]; then
                warn "检测到 WSL,但 systemd 未启用 —— 服务装上了也不会自启/被管理。"
                warn "先启用: 编辑 /etc/wsl.conf 加 [boot] 段 + systemd=true,然后在 Windows 里 wsl --shutdown 再进"
            else
                log "检测到 WSL + systemd,按普通 Linux 处理"
            fi
        fi
        ;;
    Darwin)
        die "这是 macOS,本安装器只支持 Linux(VPS/云主机/WSL)。
  替代方案: 用 Docker 或一台 Linux VPS 跑;macOS 上装 systemd 服务没有意义。"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        die "这是 Windows 的 Git Bash / MSYS,不是真 Linux —— 装不了 systemd 服务。
  三种正确姿势:
    1) WSL2(推荐): PowerShell 里 wsl --install,进 Ubuntu 后启用 systemd:
         sudo sh -c 'echo -e \"[boot]\\nsystemd=true\" > /etc/wsl.conf'
         然后在 PowerShell 里 wsl --shutdown,重进 WSL,再跑本安装器
    2) 直接用一台 Linux VPS(Debian/Ubuntu),SSH 上去跑
    3) Docker Desktop 里起一个 ubuntu 容器(需 --privileged 才能用 systemd)
  本安装器目标机必须能跑 systemd。"
        ;;
    *)
        die "不支持的系统: $OS_KERNEL(只支持 Linux,含 WSL2)"
        ;;
esac

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
    die "请用 root 运行: sudo -i 后重跑,或 sudo apikey=... bash install.sh"
fi

case "$GW_PORT" in ''|*[!0-9]*) die "GATEWAY_PORT 必须是数字: $GW_PORT" ;; esac
[ "$GW_PORT" -ge 1 ] && [ "$GW_PORT" -le 65535 ] || die "GATEWAY_PORT 越界: $GW_PORT"
case "$BUYER_PORT" in ''|*[!0-9]*) die "BUYER_PORT 必须是数字: $BUYER_PORT" ;; esac
[ "$FREE_ONLY" = "0" ] || [ "$FREE_ONLY" = "1" ] || die "FREE_ONLY 只能是 0 或 1"
[ "$AUTO_ROTATE" = "0" ] || [ "$AUTO_ROTATE" = "1" ] || die "AUTO_ROTATE 只能是 0 或 1"
case "$FALLBACK_ORDER" in
    *[!A-Za-z0-9._,-]*) die "FALLBACK_ORDER 只允许字母/数字/.-,_" ;;
esac

TMPDIR_INSTALL="$(mktemp -d)"
cleanup() {
    # 先把脚本管道的剩余内容读空,curl/wget 就不会因 EPIPE 报错(见 SELF_PIPE_FD)
    if [ -n "${SELF_PIPE_FD:-}" ]; then
        ( timeout 3 cat <&9 >/dev/null 2>&1 & ) 2>/dev/null
        eval "exec 9<&-" 2>/dev/null
    fi
    rm -rf "$TMPDIR_INSTALL"
    # 菜单从 URL 现取的可执行副本(在 /tmp,不在 TMPDIR_INSTALL 里)
    [ -n "${SELF_CACHE:-}" ] && rm -f "$SELF_CACHE" 2>/dev/null
    return 0
}
trap cleanup EXIT

# ---------------- 环境检查 ----------------
if ! { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }; then
    # --dry-run 只是预演,不该被宿主环境拦下(容器 / WSL2 / 无 systemd 的机器上也要能看流程)
    if [ "$DRY_RUN" = "1" ]; then
        warn "当前环境没有 systemd(容器 / OpenVZ / WSL1 / WSL2 未启用);DRY-RUN 继续预演,真实安装会失败"
    else
        die "需要 systemd(容器 / OpenVZ / WSL1 不支持;WSL2 请先启用 systemd)"
    fi
fi

if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
elif command -v pacman  >/dev/null 2>&1; then PM=pacman
elif command -v apk     >/dev/null 2>&1; then
    die "检测到 Alpine(apk):官方 Node 24 依赖 glibc、buyer 常驻约 240MB 内存,不支持"
else
    if [ "$DRY_RUN" = "1" ]; then
        PM=none
    else
        die "无法识别的包管理器,仅支持 apt / dnf / yum / pacman"
    fi
fi

PYBIN="$(command -v python3 || true)"
if [ "$DRY_RUN" != "1" ]; then
    [ -n "$PYBIN" ] || die "python3 未安装(apt install python3 / dnf install python3)"
    "$PYBIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' \
        || die "需要 Python >= 3.7,当前 $("$PYBIN" -V 2>&1)"
else
    PYBIN="${PYBIN:-python3}"
fi
log "Python: $("$PYBIN" -V 2>&1) ($PYBIN)"

# ---------------- 运行期管理命令:先分流 ----------------
# 无参数时进菜单(方便运维)。判断"能不能交互"要看**真实终端**,不能看 fd 0:
# `bash <(curl ...)` 会把 /dev/fd/63 当作 stdin,此时 [ -t 0 ] 是假,菜单就永远
# 不出现,用户敲的选择会被当成安装流程的输入吃掉。真终端一般挂在 /dev/tty。
# 管道喂数据的脚本场景(echo 3 | bash install.sh)仍按"直接安装"处理。
# 判定标准只有一条:**当前进程有没有可用的终端**。不要看 fd 1 ——
# 输出被重定向、被面板/日志中转、被 tee 走一遍时 [ -t 1 ] 就是假,
# 菜单会静默消失、直接开装,用户还以为安装器没有菜单。
if [ "$#" -eq 0 ] && [ "$ACTION" = "install" ] && [ "${NO_MENU:-0}" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    MENU_OK=0
    # 首选 /dev/tty:bash <(curl ...) 把 fd 0 换成了管道,终端仍挂在 /dev/tty
    if { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null; then
        if exec 3</dev/tty 4>/dev/tty 2>/dev/null; then
            MENU_TTY=1
            MENU_OK=1
        fi
    fi
    # 退路:stdin 本身就是终端(bash install.sh / ./install.sh)
    if [ "$MENU_OK" = "0" ] && [ -t 0 ]; then
        MENU_TTY=0
        MENU_OK=1
    fi
    if [ "$MENU_OK" = "1" ]; then
        ACTION=menu
    else
        warn "非交互环境,直接安装(想要菜单: bash install.sh menu)"
    fi
fi
case "$ACTION" in
    menu)
        do_menu
        exit 0 ;;
    update-cli)
        _rc=0; do_update_cli || _rc=$?; exit "$_rc" ;;
    status)  do_status; exit 0 ;;
    logs)    do_logs; exit 0 ;;
    config)  do_config; exit 0 ;;
esac

# ---------------- 卸载 ----------------
do_uninstall() {
    local u f link
    log "停止并移除服务..."
    for u in antseed-gateway antseed-buyer antseed-rotate antseed-free-filter; do
        run_q systemctl stop "$u.service" || true
        run_q systemctl disable "$u.service" || true
    done
    run_q systemctl daemon-reload || true
    run_q systemctl reset-failed antseed-gateway.service antseed-buyer.service \
        antseed-rotate.service || true

    log "清理残留进程..."
    for p in "antseed-free-filter[.]py" "antseed-gateway[.]py" "antseed buyer start"; do
        run_q pkill -f "$p" || true
    done

    log "删除 unit 与程序..."
    for f in "$GW_UNIT" "$BUYER_UNIT" "$ROTATE_UNIT" \
             /etc/systemd/system/antseed-free-filter.service; do
        run rm -f "$f"
    done
    run rm -rf "$GW_UNIT.d" "$BUYER_UNIT.d" "$ROTATE_UNIT.d"
    run rm -f "$GATEWAY_PY" "$ROTATE_SH" /usr/local/bin/antseed-free-filter.py
    run rm -f /etc/profile.d/antseed.sh /etc/profile.d/antseed-node.sh
    run rm -f /var/log/antseed-rotate.log /tmp/antseed-rotate.lock
    run rm -rf /run/antseed

    # 旧安装方式留下的命令链接:只删指向本安装目录的
    for f in node npm npx antseed; do
        link="/usr/local/bin/$f"
        if [ -L "$link" ] && readlink "$link" | grep -q "^${NODE_DIR}/"; then
            run rm -f "$link"
        fi
    done
    run rm -rf "$NODE_DIR"

    if [ "$PURGE" = "1" ]; then
        log "删除配置、节点身份与本地数据..."
        run rm -rf "$CONF_DIR" /root/.antseed
    else
        warn "已保留 $CONF_DIR 与 /root/.antseed(含节点身份)。要一并删除: bash $0 uninstall --purge"
    fi

    if [ "$DRY_RUN" != "1" ]; then
        if ss -ltn 2>/dev/null | grep -qE ":(${GW_PORT}|${BUYER_PORT})\b"; then
            warn "端口 ${GW_PORT}/${BUYER_PORT} 仍被占用: ss -ltnp | grep -E '${GW_PORT}|${BUYER_PORT}'"
        else
            log "端口已释放"
        fi
    fi
    log "卸载完成"
}

if [ "$ACTION" = "uninstall" ]; then
    do_uninstall
    exit 0
fi

# ---------------- 写程序 / unit(install 与 upgrade 共用) ----------------
# ================= 安装脚本本体结束 =================
# 以上是安装器本体。紧跟其后,只在下面 write_gateway_py() 的 heredoc 内,会嵌入
# 网关实现(gateway.py)。出现在 heredoc 之外就说明 build 的结果坏了。
write_gateway_py() {
    [ "$DRY_RUN" = "1" ] || write_file "$GATEWAY_PY" 0755 <<'ANTSEED_GATEWAY_PY_EOF'
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

# ================= 安装脚本本体结束 =================
# 下面这段 Python 是网关实现:由 tools/build-install.sh 从 gateway.py 自动嵌入。
# 它位于 heredoc 之前,一旦被 bash 当命令执行就说明
# 文件结构已损坏 —— 第 1 行会以 "python3: line 1" 之类的报错立刻暴露,而不是
# 接着往下跑出一屏 "log: command not found"。
PY_VERSION = "antseed-gateway 2.0.10"
PY_BYTES = 45383  # 构建时回填,运行期截断用
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

VERSION = "2.0.10"

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
# 回绝请求(413/400/401/404)前最多把多少"客户端还在发的 body"读掉,再关连接。
# 读掉是为了让对面能正常收到错误响应而不是 ECONNRESET;设上限是为了不被超大 body 拖住。
DRAIN_BODY = max(0, _env_int("DRAIN_BODY_MB", 8)) * 1024 * 1024
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

    def _discard_body(self, limit=DRAIN_BODY):
        """把客户端还在发的请求体吃掉(最多 limit 字节),让响应能真正送到对面。

        400/413 都是"请求体没读完就回绝":如果直接把 socket 关掉,客户端往往还没把 body
        发完,它看到的就不是我们的错误文案,而是 ECONNRESET / 连接被中止。
        """
        raw = self.headers.get("Content-Length")
        try:
            left = int(raw or 0)
        except (TypeError, ValueError):
            return
        if left <= 0:
            return
        cap = min(left, limit)
        try:
            self.connection.settimeout(1.0)
            while cap > 0:
                buf = self.rfile.read(min(cap, 65536))
                if not buf:
                    break
                cap -= len(buf)
        except (OSError, ValueError):
            pass

    def _reject_body(self, status, msg):
        """请求体没读完就回绝:必须显式关连接,并尽量先把残留 body 读掉。

        否则未读的字节会被同一个 keep-alive 连接当成下一个请求行,客户端随后收到的
        是 400 或直接断连 —— 而不是我们写好的那句错误。
        """
        self._discard_body()
        self.close_connection = True
        return self._err(status, msg, extra={"Connection": "close"})

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if not path.startswith("/v1/"):
            self._discard_body()
            self.close_connection = True
            return self._err(404, "not found: " + path, extra={"Connection": "close"})
        if not self._auth_ok():
            self._discard_body()
            self.close_connection = True
            return self._err(401, "invalid api key", "authentication_error",
                             extra={"Connection": "close"})
        try:
            body = self._read_body()
        except OverflowError:
            return self._reject_body(413, "request body larger than %dMB" % (MAX_BODY // 1024 // 1024))
        except ValueError as e:
            return self._reject_body(400, str(e))
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
ANTSEED_GATEWAY_PY_EOF
    if [ "$DRY_RUN" != "1" ]; then
        "$PYBIN" -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), "gateway.py", "exec")' \
            "$GATEWAY_PY" || die "网关程序语法检查失败"
        log "网关程序落地: $GATEWAY_PY"
    fi
}

write_rotate() {
    write_file "$ROTATE_SH" 0700 <<'ANTSEED_ROTATE_EOF'
#!/bin/sh
# 轮换 buyer 节点身份:换 identity -> 重启 buyer -> 等就绪。
# 由 antseed-rotate.service(oneshot)调用,不直接给用户手跑。
set -u

BUYER_ENV=/etc/antseed/buyer.env
BUYER_UNIT=antseed-buyer.service
UPSTREAM="${UPSTREAM:-http://127.0.0.1:8378}"
RUNDIR=/run/antseed
LOCK="$RUNDIR/rotate.lock"
LOG=/var/log/antseed-rotate.log

mkdir -p "$RUNDIR"
chmod 700 "$RUNDIR" 2>/dev/null || true

if ! mkdir "$LOCK" 2>/dev/null; then
    age=0
    if [ -d "$LOCK" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || date +%s) ))
    fi
    if [ "$age" -lt 300 ]; then
        echo "[rotate] 另一轮轮换进行中(${age}s),跳过"
        exit 0
    fi
    echo "[rotate] 清理过期锁(${age}s)"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { echo "[rotate] 抢锁失败"; exit 0; }
fi
trap 'rm -rf "$LOCK"' EXIT INT TERM

NEW="$(openssl rand -hex 32)"
if [ -f "$BUYER_ENV" ]; then
    sed -i "s/^ANTSEED_IDENTITY_HEX=.*/ANTSEED_IDENTITY_HEX=$NEW/" "$BUYER_ENV"
else
    mkdir -p /etc/antseed
    printf 'HOME=/root\nANTSEED_IDENTITY_HEX=%s\n' "$NEW" > "$BUYER_ENV"
    chmod 600 "$BUYER_ENV"
fi
echo "$(date '+%F %T') rotate -> $(printf '%s' "$NEW" | cut -c1-8)... " >> "$LOG"

systemctl restart "$BUYER_UNIT"

i=0
while [ "$i" -lt 60 ]; do
    if curl -fsS -m 3 "$UPSTREAM/v1/models" >/dev/null 2>&1; then
        echo "$(date '+%F %T') buyer ready after $((i * 2))s" >> "$LOG"
        echo "[rotate] 完成,buyer 已就绪"
        exit 0
    fi
    i=$((i + 1))
    sleep 2
done
echo "$(date '+%F %T') buyer NOT ready after 120s" >> "$LOG"
echo "[rotate] 警告: buyer 120s 内未就绪"
exit 0
ANTSEED_ROTATE_EOF
}

write_gateway_unit() {
    write_file "$GW_UNIT" 0644 <<EOF
[Unit]
Description=Antseed Gateway ${VERSION} (OpenAI/Anthropic compatible proxy)
After=network-online.target antseed-buyer.service
Wants=network-online.target antseed-buyer.service

[Service]
Type=simple
User=root
EnvironmentFile=$GW_ENV
ExecStart=$PYBIN $GATEWAY_PY
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
RuntimeDirectory=antseed
RuntimeDirectoryMode=0700
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryMax=512M
LimitNOFILE=8192
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_rotate_unit() {
    write_file "$ROTATE_UNIT" 0644 <<EOF
[Unit]
Description=Antseed buyer identity rotation (one-shot, started on demand)
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
Environment=UPSTREAM=http://127.0.0.1:$BUYER_PORT
ExecStart=$ROTATE_SH
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal
EOF
}

wait_health() {
    local i
    [ "$DRY_RUN" = "1" ] && return 0
    for i in $(seq 1 30); do
        if curl -fsS -m 2 "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------- upgrade ----------------
do_upgrade() {
    log "升级网关到 $VERSION(保留 $GW_ENV 与节点身份)..."
    if [ ! -f "$GW_ENV" ]; then
        [ "$DRY_RUN" = "1" ] && warn "干跑:$GW_ENV 不存在,真实运行会中止"
        [ "$DRY_RUN" = "1" ] || die "找不到 $GW_ENV,请先完整安装: bash $0"
    fi
    write_gateway_py
    write_rotate
    write_gateway_unit
    write_rotate_unit
    run systemctl daemon-reload
    run systemctl restart antseed-gateway.service
    if wait_health; then
        log "升级完成, /health 正常"
        [ "$DRY_RUN" = "1" ] || curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/health" | "$PYBIN" -m json.tool 2>/dev/null || true
    else
        warn "升级后 /health 30s 内未就绪: journalctl -u antseed-gateway -n 80 --no-pager"
    fi
}

if [ "$ACTION" = "upgrade" ]; then
    do_upgrade
    exit 0
fi

# ---------------- 依赖 ----------------
install_deps() {
    local missing="" p
    if ! command -v curl >/dev/null 2>&1; then
        missing="$missing curl"
    fi
    for p in openssl python3 iproute2; do
        case "$PM" in
            apt) dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p" ;;
            dnf|yum)
                if [ "$p" = "iproute2" ]; then
                    rpm -q iproute >/dev/null 2>&1 || missing="$missing iproute"
                else
                    rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
                fi ;;
            pacman)
                if [ "$p" = "python3" ]; then
                    pacman -Q python >/dev/null 2>&1 || missing="$missing python"
                else
                    pacman -Q "$p" >/dev/null 2>&1 || missing="$missing $p"
                fi ;;
            none) : ;;      # 干跑且没有包管理器:能确认的缺失(curl)照常累计,其余无法探测
        esac
    done
    if [ -z "$missing" ]; then
        log "系统依赖已齐全,跳过包管理"
        return 0
    fi
    if [ "$PM" = "none" ]; then
        warn "未识别的包管理器,无法自动安装:${missing}(干跑继续;真实安装会中止)"
        return 0
    fi
    log "安装缺失依赖:${missing}"
    case "$PM" in
        apt)
            run_q apt-get update -qq || true
            # shellcheck disable=SC2086
            run apt-get install -y -qq $missing ;;
        dnf) # shellcheck disable=SC2086
            run dnf install -y -q $missing ;;
        yum) # shellcheck disable=SC2086
            run yum install -y -q $missing ;;
        pacman) # shellcheck disable=SC2086
            run pacman -S --needed --noconfirm $missing ;;
        none) log "干跑:跳过依赖安装" ; return 0 ;;
    esac
}

install_deps
if [ "$DRY_RUN" != "1" ]; then
    PYBIN="$(command -v python3 || true)"
    [ -n "$PYBIN" ] || die "python3 仍不可用"
fi

# ---------------- Node ----------------
NODE_BIN=""
NPM_BIN=""
NODE_PREFIX=""
USE_SYSTEM=0
if [ "${SYSTEM_NODE:-1}" != "0" ] && command -v node >/dev/null 2>&1; then
    sys_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${sys_major:-0}" -ge 24 ] 2>/dev/null; then
        USE_SYSTEM=1
    else
        log "系统 Node $(node -v 2>/dev/null || echo '?') < v24,改用内置 Node"
    fi
fi

node_arch() {
    case "$(uname -m)" in
        x86_64) echo x64 ;;
        aarch64|arm64) echo arm64 ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

install_node() {
    [ "$(uname -s)" = "Linux" ] || die "仅支持 Linux,当前 $(uname -s)"
    local arch tarball url
    arch="$(node_arch)"
    tarball="node-${NODE_VERSION}-linux-${arch}.tar.xz"
    url="https://nodejs.org/dist/${NODE_VERSION}"
    if [ "$DRY_RUN" = "1" ]; then
        log "would download $url/$tarball (SHA256 校验后解压到 $NODE_DIR)"
        NODE_BIN="$NODE_DIR/bin/node"; NPM_BIN="$NODE_DIR/bin/npm"; NODE_PREFIX="$NODE_DIR"
        return 0
    fi
    if [ ! -x "$NODE_DIR/bin/node" ]; then
        log "下载 Node ${NODE_VERSION} (${arch})..."
        (
            cd "$TMPDIR_INSTALL"
            if ! download "$url/SHASUMS256.txt" SHASUMS256.txt; then
                die "拿不到 Node ${NODE_VERSION} 的校验文件(版本可能不存在),用 NODE_VERSION=vX.Y.Z 指定实际版本"
            fi
            download "$url/$tarball" "$tarball"
            grep " ${tarball}\$" SHASUMS256.txt > "$tarball.sha256" \
                || die "SHASUMS256.txt 中没有 $tarball"
            sha256sum -c "$tarball.sha256" >/dev/null || die "Node 安装包 SHA256 校验失败"
            mkdir -p "$NODE_DIR"
            tar -xJf "$tarball" -C "$NODE_DIR" --strip-components=1
        )
        log "Node 校验通过: $("$NODE_DIR/bin/node" -v)"
    else
        log "复用已安装的内置 Node: $("$NODE_DIR/bin/node" -v)"
    fi
    NODE_BIN="$NODE_DIR/bin/node"
    NPM_BIN="$NODE_DIR/bin/npm"
    NODE_PREFIX="$NODE_DIR"
    # npm 的 shebang 是 `#!/usr/bin/env node`,子进程必须能在 PATH 里找到 node。
    # 只写 /etc/profile.d 对**当前进程**无效(那只影响下次登录 shell),所以这里
    # 同时把 $NODE_DIR/bin 前置进本次运行的 PATH —— 否则 npm install -g 会以
    # `env: 'node': No such file or directory` 失败。
    case ":$PATH:" in
        *":$NODE_DIR/bin:"*) ;;
        *) [ "$DRY_RUN" = "1" ] || PATH="$NODE_DIR/bin:$PATH"; export PATH ;;
    esac
    write_file /etc/profile.d/antseed-node.sh 0644 <<EOF
# 由 antseed-gateway 安装器写入
case ":\$PATH:" in
    *":$NODE_DIR/bin:"*) ;;
    *) PATH="$NODE_DIR/bin:\$PATH"; export PATH ;;
esac
EOF
}

if [ "$USE_SYSTEM" = "1" ]; then
    NODE_BIN="$(command -v node)"
    NPM_BIN="$(command -v npm || true)"
    [ -n "$NPM_BIN" ] || die "系统 Node 缺少 npm,请安装完整 nodejs 包"
    NODE_PREFIX="$("$NPM_BIN" prefix -g 2>/dev/null || echo /usr/local)"
    log "复用系统 Node: $(node -v) (prefix=$NODE_PREFIX)"
else
    [ "${SKIP_NODE:-0}" = "1" ] && die "SKIP_NODE=1 但系统 Node 不可用(需要 >= v24)"
    install_node
fi

ANTSEED_BIN="$NODE_PREFIX/bin/antseed"

# npm 11 起默认不执行依赖的 install/preinstall 脚本。@antseed/node(better-sqlite3 /
# keytar / node-datachannel)靠这些脚本拉预编译产物或就地编译,不放行的话在缺少
# 对应平台预编译包的机器(如 arm64)上装出来的 CLI 会缺原生模块。
# 老版本 npm 不认识这个参数(会报 Unknown option),所以先探测再决定传不传。
NPM_ALLOW=""
if [ "$DRY_RUN" != "1" ] && "$NPM_BIN" install --help 2>/dev/null | grep -q -- '--allow-scripts'; then
    NPM_ALLOW="--allow-scripts=@antseed/node,better-sqlite3,keytar,node-datachannel"
    log "npm 支持 --allow-scripts,放行 4 个原生依赖的构建脚本"
fi

install_cli() {
    if [ -x "$ANTSEED_BIN" ] && [ "${FORCE_INSTALL:-0}" != "1" ]; then
        log "@antseed/cli 已装: $("$NODE_BIN" "$ANTSEED_BIN" --version 2>/dev/null || echo '?') (重装: FORCE_INSTALL=1)"
        return 0
    fi
    log "安装 @antseed/cli@${CLI_VERSION} ..."
    # shellcheck disable=SC2086  # NPM_ALLOW 为空时要展开成 0 个参数,不能加引号
    run "$NPM_BIN" install -g "@antseed/cli@${CLI_VERSION}" --no-audit --no-fund $NPM_ALLOW
    if [ "$DRY_RUN" != "1" ] && [ ! -x "$ANTSEED_BIN" ]; then
        warn "CLI 未就绪,安装编译依赖后重试一次"
        case "$PM" in
            apt) run apt-get install -y -qq build-essential python3-dev ;;
            dnf|yum) run "$PM" install -y -q gcc gcc-c++ make python3-devel ;;
            pacman) run pacman -S --needed --noconfirm base-devel python ;;
            none) : ;;
        esac
        # shellcheck disable=SC2086
        run "$NPM_BIN" install -g "@antseed/cli@${CLI_VERSION}" --no-audit --no-fund $NPM_ALLOW
    fi
    [ "$DRY_RUN" = "1" ] || [ -x "$ANTSEED_BIN" ] || die "CLI 安装失败:$ANTSEED_BIN 不存在"
}

install_cli

# ---------------- 停旧实例 ----------------
stop_old() {
    local u i
    for u in antseed-gateway antseed-free-filter; do
        run_q systemctl stop "$u.service" || true
    done
    run_q pkill -f "antseed-free-filter[.]py" || true
    run_q pkill -f "antseed-gateway[.]py" || true
    [ "$DRY_RUN" = "1" ] && return 0
    for i in $(seq 1 30); do
        ss -ltn 2>/dev/null | grep -qE ":${GW_PORT}\b" || return 0
        sleep 1
    done
    warn "端口 ${GW_PORT} 仍被占用: ss -ltnp | grep ':${GW_PORT}'"
}
stop_old

# ---------------- API key ----------------
API_KEY="${API_KEY:-${apikey:-}}"
OLD_KEY=""
if [ -f "$GW_ENV" ]; then
    OLD_KEY="$(sed -n 's/^ANTSEED_API_KEY=//p' "$GW_ENV" | head -1)"
fi
if [ -z "$API_KEY" ] && [ -n "$OLD_KEY" ]; then
    API_KEY="$OLD_KEY"
    log "复用已有 API key(要换: apikey=新key bash $0 --key=新key)"
fi
if [ -z "$API_KEY" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        API_KEY="sk-antseed-dryrun000000000000000000000000"
    else
        API_KEY="sk-antseed-$(openssl rand -hex 16)"
        log "已自动生成 API key"
    fi
elif [ -n "$OLD_KEY" ] && [ "$API_KEY" != "$OLD_KEY" ]; then
    warn "API key 已变更,记得同步更新客户端配置"
fi
case "$API_KEY" in
    *[!A-Za-z0-9._~+/=-]*) die "API key 只允许 [A-Za-z0-9._~+/=-](不能含空格/引号/换行)" ;;
esac
[ "${#API_KEY}" -ge 16 ] || warn "API key 只有 ${#API_KEY} 字符,建议 >= 32"

# ---------------- 节点身份(默认复用) ----------------
IDENTITY_HEX=""
if [ "${FORCE_ROTATE:-0}" != "1" ]; then
    for f in "$BUYER_ENV" "$BUYER_UNIT"; do
        [ -f "$f" ] || continue
        IDENTITY_HEX="$(sed -n 's/.*ANTSEED_IDENTITY_HEX=//p' "$f" 2>/dev/null \
                        | head -1 | tr -cd '0-9a-fA-F')"
        if [ "${#IDENTITY_HEX}" -ne 64 ]; then IDENTITY_HEX=""; fi
        if [ -n "$IDENTITY_HEX" ]; then
            log "复用已有节点身份: ${IDENTITY_HEX:0:8}..."
            break
        fi
    done
fi
if [ -z "$IDENTITY_HEX" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        IDENTITY_HEX="$(printf '0%.0s' $(seq 1 64))"
    else
        IDENTITY_HEX="$(openssl rand -hex 32)"
        log "生成新节点身份: ${IDENTITY_HEX:0:8}..."
    fi
fi

# ---------------- 配置 ----------------

write_file "$BUYER_ENV" 0600 <<EOF
# buyer 运行环境(安装器写入;身份由 antseed-rotate.service 更新)
HOME=/root
ANTSEED_IDENTITY_HEX=$IDENTITY_HEX
EOF

write_gateway_env_fresh() {
    write_file "$GW_ENV" 0600 <<EOF
# antseed-gateway 配置。改完执行: systemctl restart antseed-gateway
# 这是网关唯一的可调入口;升级安装脚本不会覆盖它。
ANTSEED_API_KEY=$API_KEY
FREE_ONLY=$FREE_ONLY
GATEWAY_PORT=$GW_PORT
GATEWAY_BIND=$GW_BIND
UPSTREAM=http://127.0.0.1:$BUYER_PORT

# ---- 探活 / 回退 ----
PROBE_INTERVAL=300
PROBE_TIMEOUT=45
PROBE_WORKERS=4
FAIL_THRESHOLD=2
BLACKLIST_SECONDS=900
SOFT_COOLDOWN=180          # 402/429 的冷却,比上面短:换个 peer 往往就好了
DEPOSIT_COOLDOWN=60        # 402 押金不足的冷却:充值或换个 $0 peer 就好,别长时间拉黑
DEPOSIT_STATUS=400         # 押金不足回给客户端的 HTTP 状态。别改回 402:很多客户端见 402 就显示"额度用尽"
AUTO_FALLBACK=1            # model=auto 失败时换模型
FALLBACK_NAMED=0           # 点名模型失败时是否换模型(0=照实报错,和 v1 一致)
MAX_ATTEMPTS=3
FALLBACK_ORDER=$FALLBACK_ORDER

# ---- 流式 / 超时 ----
STREAM_IDLE_TIMEOUT=90
NONSTREAM_TIMEOUT=300
CLIENT_TIMEOUT=300

# ---- 限额 ----
MAX_CONCURRENCY=64
MAX_BODY_MB=64
DRAIN_BODY_MB=8            # 回绝请求前最多读掉多少残留 body(读掉再关连接,客户端才不会看到连接被重置)
MODELS_TTL=60

# ---- 402 换身份(默认关闭,开启前读 README 的风险说明) ----
AUTO_ROTATE=$AUTO_ROTATE
ROTATE_UNIT=antseed-rotate.service

# ---- 访问日志 ----
ACCESS_LOG=1
EOF
}

if [ -f "$GW_ENV" ]; then
    log "复用已有 $GW_ENV:只更新显式传入的项,其余(含手改)保留"
    if [ "$GIVEN_KEY" = "1" ]; then env_set "$GW_ENV" ANTSEED_API_KEY "$API_KEY"; fi
    if [ "$GIVEN_FREE_ONLY" = "1" ]; then env_set "$GW_ENV" FREE_ONLY "$FREE_ONLY"; fi
    if [ "$GIVEN_PORT" = "1" ]; then env_set "$GW_ENV" GATEWAY_PORT "$GW_PORT"; fi
    if [ "$GIVEN_BIND" = "1" ]; then env_set "$GW_ENV" GATEWAY_BIND "$GW_BIND"; fi
    env_set "$GW_ENV" UPSTREAM "http://127.0.0.1:$BUYER_PORT"
else
    write_gateway_env_fresh
fi

# 生效值以文件为准(可能保留了你的手改)
if [ "$DRY_RUN" != "1" ] && [ -f "$GW_ENV" ]; then
    _v="$(read_env FREE_ONLY "$GW_ENV")"; if [ -n "$_v" ]; then FREE_ONLY="$_v"; fi
    _v="$(read_env GATEWAY_PORT "$GW_ENV")"; if [ -n "$_v" ]; then GW_PORT="$_v"; fi
    _v="$(read_env GATEWAY_BIND "$GW_ENV")"; if [ -n "$_v" ]; then GW_BIND="$_v"; fi
fi
if [ "$FREE_ONLY" = "1" ]; then PRICE_CAP=0; else PRICE_CAP=25; fi

write_file /root/.antseed/config.json 0600 <<EOF
{
  "buyer": {
    "routingPreferences": {
      "preferFreePeers": true,
      "maxInputUsdPerMillion": $PRICE_CAP,
      "maxOutputUsdPerMillion": $PRICE_CAP,
      "minTrustScore": 0
    }
  }
}
EOF

# ---------------- 程序 + unit ----------------
write_gateway_py
write_rotate

write_file "$BUYER_UNIT" 0644 <<EOF
[Unit]
Description=Antseed buyer (P2P inference client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
EnvironmentFile=$BUYER_ENV
ExecStart=$NODE_BIN $ANTSEED_BIN buyer start --port $BUYER_PORT
Restart=always
RestartSec=10
TimeoutStopSec=20
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

write_gateway_unit
write_rotate_unit

log "启动服务..."
run systemctl daemon-reload
run_q systemctl enable antseed-buyer.service || true
run systemctl restart antseed-buyer.service

wait_upstream() {
    local i
    [ "$DRY_RUN" = "1" ] && return 0
    for i in $(seq 1 45); do
        if curl -fsS -m 3 "http://127.0.0.1:$BUYER_PORT/v1/models" >/dev/null 2>&1; then
            log "buyer 就绪 (port $BUYER_PORT, 约 $((i * 2 - 2))s)"
            return 0
        fi
        sleep 2
    done
    return 1
}
if ! wait_upstream; then
    warn "buyer 90s 内未在 ${BUYER_PORT} 就绪,继续装网关"
    warn "  journalctl -u antseed-buyer -n 40 --no-pager"
    if [ "$DRY_RUN" != "1" ] && command -v ss >/dev/null 2>&1; then
        # buyer 若被别的东西占了默认端口,这里能直接看出实际监听在哪
        ss -ltnp 2>/dev/null | grep -E ":(${BUYER_PORT}|${GW_PORT})\b" || true
        if ss -ltn 2>/dev/null | grep -qE ":${GW_PORT}\b"; then
            warn "注意: ${GW_PORT} 已被占用,网关将无法监听,先清掉: ss -ltnp | grep ':${GW_PORT}'"
        fi
    fi
fi

run_q systemctl enable antseed-gateway.service || true
run systemctl restart antseed-gateway.service

# ---------------- 自检 ----------------
if [ "$DRY_RUN" != "1" ]; then
    log "等待网关就绪..."
    if wait_health; then
        health="$(curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/health" || echo '{}')"
        models="$(curl -fsS -m 30 -H "Authorization: Bearer $API_KEY" \
                    "http://127.0.0.1:$GW_PORT/v1/models" 2>/dev/null || echo '{}')"
        n_models="$(printf '%s' "$models" | "$PYBIN" -c \
            'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null || echo '?')"
        log "自检通过: /health OK, /v1/models 返回 ${n_models} 个条目"
        printf '%s' "$health" | "$PYBIN" -c \
            'import sys,json;d=json.load(sys.stdin);print("      healthy:", ", ".join(d.get("healthy") or ["(首轮探活中)"]) or "-", "-> auto 落到:", d.get("will_route_to") or "-")' \
            2>/dev/null || true
        # 首轮探活要几十秒,等它出结果,再真发一次请求——"能列出模型"和"能推理"是两件事
        log "等待首轮探活完成(最多 90s)..."
        for i in $(seq 1 45); do
            if curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/health" 2>/dev/null \
               | grep -q '"healthy": \["'; then break; fi
            sleep 2
        done
        reply="$(curl -fsS -m 90 -X POST "http://127.0.0.1:$GW_PORT/v1/chat/completions" \
            -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
            -d '{"model":"auto","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null || true)"
        if printf '%s' "$reply" | grep -q '"choices"'; then
            log "端到端自检通过: 真实补全请求成功 (model=auto)"
        else
            warn "真实补全请求未成功,先看: journalctl -u antseed-gateway -n 60 --no-pager"
            warn "  常见原因: 节点刚上线还没被 P2P 网络分配到 peer,过几分钟再试"
        fi
    else
        warn "网关 30s 内未响应 /health: journalctl -u antseed-gateway -n 80 --no-pager"
    fi
fi

# ---------------- 公网地址 ----------------
detect_ip() {
    # 单独开子 shell 并摘掉 ERR trap:探测公网 IP 时逐个接口试,失败是正常流程,
    # 不能让 "中断于第 N 行" 这种提示吓到用户(脚本本来会继续)。
    (
        trap - ERR
        set +e
        if [ -n "${PUBLIC_HOST:-}" ]; then printf '%s' "$PUBLIC_HOST"; exit 0; fi
        ip=""
        for u in https://api.ipify.org https://ipv4.icanhazip.com https://ip.sb; do
            ip="$(curl -4 -fsS -m 4 "$u" 2>/dev/null | tr -d '[:space:]')"
            case "$ip" in
                ""|*[!0-9.]*) ;;
                *) printf '%s' "$ip"; exit 0 ;;
            esac
        done
        ip="$(curl -6 -fsS -m 4 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$ip" ]; then printf '[%s]' "$ip"; else printf '127.0.0.1'; fi
    )
}
[ "$DRY_RUN" = "1" ] || VPS_IP="$(detect_ip)"
VPS_IP="${VPS_IP:-127.0.0.1}"

echo ""
echo "=================================================="
echo "  Antseed Gateway ${VERSION} 安装完成"
echo "=================================================="
echo ""
echo "  代理地址:  http://${VPS_IP}:${GW_PORT}/v1"
echo "  API Key:   ${API_KEY}"
echo "  模型过滤:  FREE_ONLY=${FREE_ONLY} (1=仅免费, 0=全部)"
case "$GW_BIND" in
    *:*) BIND_DISPLAY="[${GW_BIND}]" ;;
    *)   BIND_DISPLAY="$GW_BIND" ;;
esac
echo "  监听:      ${BIND_DISPLAY}:${GW_PORT}    (改 ${GW_ENV})"
echo "  自动换身份: AUTO_ROTATE=${AUTO_ROTATE}"
echo ""
echo "  Hermes / OpenAI SDK:"
echo "    base_url: http://${VPS_IP}:${GW_PORT}/v1"
echo "    api_key:  ${API_KEY}"
echo "    model:    auto          # 也可写具体模型名"
echo ""
echo "  常用命令:"
echo "    systemctl status antseed-gateway"
echo "    journalctl -u antseed-gateway -f"
echo "    curl -s http://127.0.0.1:${GW_PORT}/health | python3 -m json.tool"
echo "    curl -s -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${GW_PORT}/v1/models"
echo "    curl -s -H 'Authorization: Bearer ${API_KEY}' http://127.0.0.1:${GW_PORT}/v1/health/detail"
echo ""
if [ "$GW_BIND" = "127.0.0.1" ] || [ "$GW_BIND" = "localhost" ]; then
    echo "  当前只监听本机。要从外面访问: 把 ${GW_ENV} 里 GATEWAY_BIND 改成 :: 或 0.0.0.0,"
    echo "  并强烈建议在前面挂 TLS 反代(Caddy/Nginx),否则 API key 与 prompt 都是明文过网。"
    echo ""
fi
echo "  升级:  bash install.sh upgrade"
echo "  卸载:  bash install.sh uninstall [--purge]"
echo "=================================================="
