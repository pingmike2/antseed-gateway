#!/usr/bin/env bash
# 由 install.sh.tpl + gateway.py 生成自包含的 install.sh,保证两者永远同步。
# 改完 gateway.py 或 tpl 后跑一次: bash tools/build-install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TPL="install.sh.tpl"
GW="gateway.py"
OUT="install.sh"
MARK="@@GATEWAY_PY@@"

[ -f "$TPL" ] || { echo "缺少 $TPL" >&2; exit 1; }
[ -f "$GW" ]  || { echo "缺少 $GW"  >&2; exit 1; }

python3 - "$TPL" "$GW" "$OUT" "$MARK" <<'PY'
import sys
tpl, gw, out, mark = sys.argv[1:5]
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
open(out, "w", encoding="utf-8").write(text)
PY

chmod 0755 "$OUT"
bash -n "$OUT" || { echo "install.sh 语法检查失败" >&2; exit 1; }

# 反向校验:从生成的 install.sh 里抽回 gateway.py,必须与源文件逐字节一致
python3 - "$OUT" "$GW" <<'PY'
import sys
out, gw = sys.argv[1:3]
lines = open(out, encoding="utf-8").read().splitlines(True)
start = next(i for i, l in enumerate(lines) if "ANTSEED_GATEWAY_PY_EOF" in l and "<<" in l) + 1
end = next(i for i in range(start, len(lines)) if lines[i] == "ANTSEED_GATEWAY_PY_EOF\n")
extracted = "".join(lines[start:end])
src = open(gw, encoding="utf-8").read()
if not src.endswith("\n"):
    src += "\n"
if extracted != src:
    import difflib
    sys.exit("同步校验失败:\n" + "".join(list(difflib.unified_diff(
        src.splitlines(True), extracted.splitlines(True), "gateway.py", "install.sh 内嵌"))[:40]))
print(f"OK  install.sh 已生成 ({len(lines)} 行), 内嵌 gateway.py 与源文件一致 ({len(extracted.splitlines())} 行)")
PY
