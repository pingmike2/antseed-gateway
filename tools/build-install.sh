#!/usr/bin/env bash
# 由 install.sh.tpl + gateway.py 生成自包含的 install.sh,保证两者永远同步。
# 改完 gateway.py 或 tpl 后跑一次: bash tools/build-install.sh
# 只校验是否同步(不改任何文件,CI 可用): bash tools/build-install.sh --check
set -euo pipefail
cd "$(dirname "$0")/.."

TPL="install.sh.tpl"
GW="gateway.py"
OUT="install.sh"
MARK="@@GATEWAY_PY@@"
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

[ -f "$TPL" ] || { echo "缺少 $TPL" >&2; exit 1; }
[ -f "$GW" ]  || { echo "缺少 $GW"  >&2; exit 1; }

python3 - "$TPL" "$GW" "$OUT" "$MARK" "$CHECK" <<'PY'
import sys
tpl, gw, out, mark, check = sys.argv[1:6]
check = (check == "1")
body = open(gw, encoding="utf-8").read()
if not body.endswith("\n"):
    body += "\n"
text = open(tpl, encoding="utf-8").read()
if text.count(mark) != 1:
    sys.exit(f"{tpl}: 标记 {mark} 必须恰好出现 1 次,实际 {text.count(mark)} 次")
if mark + "\n" in text:
    text = text.replace(mark + "\n", body)
else:
    text = text.replace(mark, body)
data = text.encode("utf-8")
try:
    old = open(out, "rb").read()
except FileNotFoundError:
    old = None
lines = data.count(b"\n")
if old == data:
    print(f"OK  {out} 已是最新 ({lines} 行, 与 {tpl}+{gw} 逐字节一致)")
elif check:
    sys.exit(f"{out} 与 {tpl}+{gw} 不同步,请运行: bash tools/build-install.sh")
else:
    # 二进制写:强制 LF,避免 Windows 文本模式生成 CRLF 造成整文件假 diff
    open(out, "wb").write(data)
    print(f"已更新 {out} ({lines} 行)")
PY

if [ "$CHECK" = "0" ]; then
  chmod 0755 "$OUT" 2>/dev/null || true
fi
bash -n "$OUT" || { echo "install.sh 语法检查失败" >&2; exit 1; }

# 反向校验:从生成的 install.sh 里抽回 gateway.py,必须与源文件逐字节一致
python3 - "$OUT" "$GW" <<'PY'
import sys
out, gw = sys.argv[1:3]
lines = open(out, encoding="utf-8").read().splitlines(True)
start = next(i for i, l in enumerate(lines) if "ANTSEED_GATEWAY_PY_EOF" in l and "<<" in l) + 1
end = next(i for i in range(start, len(lines)) if lines[i].rstrip("\r\n") == "ANTSEED_GATEWAY_PY_EOF")
extracted = "".join(lines[start:end])
src = open(gw, encoding="utf-8").read()
if not src.endswith("\n"):
    src += "\n"
if extracted != src:
    import difflib
    sys.exit("同步校验失败:\n" + "".join(list(difflib.unified_diff(
        src.splitlines(True), extracted.splitlines(True), "gateway.py", "install.sh 内嵌"))[:40]))
print(f"OK  install.sh 内嵌 gateway.py 与源文件一致 ({len(extracted.splitlines())} 行)")
PY
