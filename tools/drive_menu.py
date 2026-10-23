#!/usr/bin/env python3
"""交互式驱动安装器菜单,逐行喂输入并采集全部输出。"""
import os, pty, select, sys, time

CMD = sys.argv[1]
STEPS = eval(sys.argv[2])          # [(等待秒数, 文本), ...]
TIMEOUT = float(sys.argv[3]) if len(sys.argv) > 3 else 180.0

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "dumb"
    os.execvp("bash", ["bash", "-lc", CMD])

buf = b""
steps = list(STEPS)
deadline = time.time() + TIMEOUT
next_send = time.time() + steps[0][0] if steps else 1e18

while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    if steps and time.time() >= next_send:
        _, text = steps.pop(0)
        os.write(fd, text.encode())
        next_send = time.time() + (steps[0][0] if steps else 1e18)

try:
    os.close(fd)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass

sys.stdout.write(buf.decode("utf-8", "replace"))
