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
if [ "$#" -eq 0 ] && [ "$ACTION" = "install" ] && [ "${NO_MENU:-0}" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    if [ -t 1 ] && { [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }; }; then
        # 让菜单从 /dev/tty 读,避免被 <(curl ...) 的 fd 顶掉标准输入
        if [ -r /dev/tty ] && [ -w /dev/tty ]; then
            exec 3</dev/tty 4>/dev/tty 2>/dev/null && MENU_TTY=1
        fi
        ACTION=menu
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
@GATEWAY_PY_MARK@
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
