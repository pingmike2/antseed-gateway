#!/usr/bin/env bash
# Antseed Gateway 仅升级网关程序(不动 Node / CLI / 配置 / 节点身份)
#
# 用法:
#   bash upgrade.sh                     # 用同目录下的 gateway.py 升级
#   bash upgrade.sh /path/to/gateway.py
#   bash upgrade.sh --dry-run           # 只看会做什么
#   bash upgrade.sh --keep              # 不重启服务(下次重启生效)
#
# 特点:升级前备份旧程序,升级后自检 /health,失败自动回滚。

set -Eeuo pipefail

GATEWAY_PY="/usr/local/bin/antseed-gateway.py"
GW_ENV="/etc/antseed/gateway.env"
SERVICE="antseed-gateway.service"
DRY_RUN=0
DO_RESTART=1
SRC=""

log()  { printf '[upgrade] %s\n' "$*"; }
die()  { printf '[upgrade] %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        --keep) DO_RESTART=0 ;;
        -*) die "未知参数: $arg" ;;
        *) SRC="$arg" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || [ "$DRY_RUN" = "1" ] || die "请用 root 运行"
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || die "需要 systemd"

if [ -z "$SRC" ]; then
    for cand in "$(dirname "${BASH_SOURCE[0]}")/gateway.py" ./gateway.py; do
        [ -f "$cand" ] && { SRC="$cand"; break; }
    done
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || die "找不到 gateway.py,请显式给出路径: bash upgrade.sh /path/to/gateway.py"

PYBIN="$(command -v python3 || true)"
[ -n "$PYBIN" ] || die "需要 python3"
"$PYBIN" -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$SRC" \
    || die "新程序语法检查失败,已中止(线上版本未改动)"
NEW_VER="$("$PYBIN" - "$SRC" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^VERSION\s*=\s*"([^"]+)"', src, re.M)
print(m.group(1) if m else "unknown")
PY
)"
OLD_VER="unknown"
if [ -f "$GATEWAY_PY" ]; then
    OLD_VER="$("$PYBIN" - "$GATEWAY_PY" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^VERSION\s*=\s*"([^"]+)"', src, re.M)
print(m.group(1) if m else "unknown")
PY
)"
fi
log "网关程序: $OLD_VER -> $NEW_VER ($SRC)"

if [ "$DRY_RUN" = "1" ]; then
    log "would backup $GATEWAY_PY -> $GATEWAY_PY.bak"
    log "would install $SRC -> $GATEWAY_PY (0755)"
    [ "$DO_RESTART" = "1" ] && log "would run: systemctl restart $SERVICE && curl /health"
    exit 0
fi

BACKUP=""
if [ -f "$GATEWAY_PY" ]; then
    BACKUP="$GATEWAY_PY.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$GATEWAY_PY" "$BACKUP"
    log "已备份: $BACKUP"
fi

install -m 0755 "$SRC" "$GATEWAY_PY"
log "已安装: $GATEWAY_PY"

[ "$DO_RESTART" = "1" ] || { log "--keep: 下次重启生效"; exit 0; }

systemctl restart "$SERVICE"

GW_PORT="$(sed -n 's/^GATEWAY_PORT=\([0-9]\+\).*/\1/p' "$GW_ENV" 2>/dev/null | head -1)"
GW_PORT="${GW_PORT:-8377}"

ok=0
for _ in $(seq 1 30); do
    if curl -fsS -m 2 "http://127.0.0.1:${GW_PORT}/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
done

if [ "$ok" = "1" ]; then
    log "自检通过:"
    curl -fsS -m 5 "http://127.0.0.1:${GW_PORT}/health" | "$PYBIN" -m json.tool 2>/dev/null || true
    exit 0
fi

log "自检失败,/health 30s 内无响应,开始回滚"
if [ -n "$BACKUP" ]; then
    install -m 0755 "$BACKUP" "$GATEWAY_PY"
    systemctl restart "$SERVICE"
    sleep 3
    if curl -fsS -m 3 "http://127.0.0.1:${GW_PORT}/health" >/dev/null 2>&1; then
        log "已回滚到 $OLD_VER,服务正常"
    else
        log "回滚后仍不正常: journalctl -u $SERVICE -n 100 --no-pager"
    fi
else
    log "没有备份可回滚"
fi
exit 1
