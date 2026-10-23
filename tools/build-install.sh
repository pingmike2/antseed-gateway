#!/usr/bin/env bash
# 由 install.sh.tpl + gateway.py 生成自包含的 install.sh,保证两者永远同步。
# 改完 gateway.py 或 tpl 后跑一次: bash tools/build-install.sh
# 只校验是否同步(不改任何文件,CI 可用): bash tools/build-install.sh --check
#
# 生成物三道自检,专治"内嵌块跑到 heredoc 外面"这种结构损坏:
#   1. bash -n 语法检查
#   2. 内嵌块必须出现且仅出现一次,位置在 heredoc 起点与终点之间
#   3. 反向抽出的内容必须与 gateway.py 逐字节一致
# 另外:占位替换一律在行首做,绝不用 str.replace 直接替换子串。
set -euo pipefail
cd "$(dirname "$0")/.."

TPL="install.sh.tpl"
GW="gateway.py"
OUT="install.sh"
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

[ -f "$TPL" ] || { echo "缺少 $TPL" >&2; exit 1; }
[ -f "$GW" ]  || { echo "缺少 $GW"  >&2; exit 1; }

python3 - "$TPL" "$GW" "$OUT" "$CHECK" <<'PY'
import sys

tpl, gw, out, chk = sys.argv[1:5]
check = (chk == "1")
MARK = "@GATEWAY_PY_MARK@"
EOF_MARK = "ANTSEED_GATEWAY_PY_EOF"

body = open(gw, encoding="utf-8").read()
if not body.endswith("\n"):
    body += "\n"
blines = body.splitlines()
if any(l.strip() == EOF_MARK for l in blines):
    sys.exit(f"{gw}: 不得包含独立成行的 {EOF_MARK}(会提前闭合 heredoc)")

# PY_BYTES 回填:迭代到十进制长度稳定为止
idx = next((i for i, l in enumerate(blines) if l.startswith("PY_BYTES = ")), None)
if idx is None:
    sys.exit(f"{gw}: 缺少 PY_BYTES 标记行")
for _ in range(5):
    body = "".join(l + "\n" for l in blines)
    new = "PY_BYTES = %d  # 构建时回填,运行期截断用" % len(body.encode("utf-8"))
    if blines[idx] == new:
        break
    blines[idx] = new
body = "".join(l + "\n" for l in blines)
# 自校验基准:把回填后的 PY_BYTES 还原成占位值再比,保证构建幂等
canon = "".join(
    ("PY_BYTES = 0  # build-time placeholder\n" if i == idx else l + "\n")
    for i, l in enumerate(blines))

# 在行首替换占位行;该行不会和 body 里的任何一行相等(否则说明 tpl 被写坏)
# gate:出现"脚本本体结束"注释之后才允许落内嵌块,防止占位被写到文件顶部
out_lines, hit, gate = [], 0, False
GUARD = "安装脚本本体结束"
for line in open(tpl, encoding="utf-8").read().split("\n"):
    if line == MARK:
        hit += 1
        if not gate:
            sys.exit(f"{tpl}: 占位行 {MARK} 出现在脚本本体结束之前(内嵌块会被当 bash 执行)")
        out_lines.append(body.rstrip("\n"))
    else:
        out_lines.append(line)
    if GUARD in line:
        gate = True
if hit != 1:
    sys.exit(f"{tpl}: 占位行 {MARK} 必须恰好 1 行,实际 {hit} 行")

data = ("\n".join(out_lines)).encode("utf-8")
try:
    old = open(out, "rb").read()
except FileNotFoundError:
    old = None
n = data.count(b"\n")
if old == data:
    print(f"OK  {out} 已是最新 ({n} 行, 与 {tpl}+{gw} 逐字节一致)")
elif check:
    sys.exit(f"{out} 与 {tpl}+{gw} 不同步,请运行: bash tools/build-install.sh")
else:
    open(out, "wb").write(data)  # 二进制写:强制 LF,避免 Windows 文本模式产生 CRLF 假 diff
    print(f"已更新 {out} ({n} 行, 内嵌 gateway.py {len(body.encode('utf-8'))} 字节)")
PY

if [ "$CHECK" = "0" ]; then
  chmod 0755 "$OUT" 2>/dev/null || true
fi

# ---- 结构闸门:内嵌块必须在 heredoc 里,且与 gateway.py 一致 ----
python3 - "$OUT" "$GW" <<'PY'
import sys, difflib

out, gw = sys.argv[1:3]
src = open(out, encoding="utf-8").read()
if not src.startswith("#!"):
    sys.exit("install.sh 第一行不是 shebang(结构损坏)")
mark = "<<'ANTSEED_GATEWAY_PY_EOF'\n"
if src.count(mark) != 1:
    sys.exit(f"install.sh 里 heredoc 起点应恰好 1 处,实际 {src.count(mark)} 处")
head, _, tail = src.partition(mark)
body, sep, rest = tail.partition("\nANTSEED_GATEWAY_PY_EOF\n")
if not sep:
    sys.exit("install.sh 里找不到 heredoc 终点(结构损坏)")
if "升级:" not in rest or "卸载:" not in rest:
    sys.exit("install.sh 缺少收尾段(尾巴被截断)")

want = open(gw, encoding="utf-8").read()
if not want.endswith("\n"):
    want += "\n"
# PY_BYTES 在生成时被回填过,比对前把那一行还原成占位值再比
wlines = want.split("\n")
wi = next((i for i, l in enumerate(wlines) if l.startswith("PY_BYTES = ")), None)
if wi is not None:
    wlines[wi] = "PY_BYTES = 0  # build-time placeholder"
    want = "\n".join(wlines)
blines = body.split("\n")
bi = next((i for i, l in enumerate(blines) if l.startswith("PY_BYTES = ")), None)
if bi is not None:
    blines[bi] = "PY_BYTES = 0  # build-time placeholder"
got = "\n".join(blines)
if got.rstrip("\n") + "\n" != want.rstrip("\n") + "\n":
    sys.exit("内嵌块与 gateway.py 不一致:\n" + "".join(list(difflib.unified_diff(
        want.splitlines(True), got.splitlines(True), gw, "install.sh 内嵌"))[:40]))
print(f"OK  内嵌块在 heredoc 内(第 {head.count(chr(10)) + 2} 行起),与 {gw} 逐字节一致")
PY

bash -n "$OUT" || { echo "install.sh 语法检查失败" >&2; exit 1; }
echo "OK  bash -n 通过"
