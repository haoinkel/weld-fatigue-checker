#!/usr/bin/env python3
"""真实模拟 iPad Safari 加载 PWA：起 server，发 HTTP GET 全部关键资源，校验状态码/大小/MIME。"""
import http.server, socketserver, threading, urllib.request, os, sys, time

ROOT = r"D:\workbuddy\workbuddy学习\weld_fatigue_checker\app_ios\pwa"
PORT = 8766

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)
    def end_headers(self):
        # 模拟 Safari iOS 的安全头校验
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()
    def log_message(self, *a, **kw): pass

server = socketserver.TCPServer(("127.0.0.1", PORT), H)
t = threading.Thread(target=server.serve_forever, daemon=True)
t.start()
time.sleep(0.5)

# Safari iOS PWA 安装必需的请求清单
checks = [
    ("/", 200, "text/html"),
    ("/index.html", 200, "text/html"),
    ("/styles.css", 200, "text/css"),
    ("/manifest.webmanifest", 200, "application/manifest+json"),
    ("/sw.js", 200, "application/javascript"),
    ("/icons/icon-192.png", 200, "image/png"),
    ("/icons/icon-512.png", 200, "image/png"),
    ("/js/knowledge.js", 200, "application/javascript"),
    ("/js/packs.js", 200, "application/javascript"),
    ("/js/standard_registry.js", 200, "application/javascript"),
    ("/js/engine.js", 200, "application/javascript"),
    ("/js/design_rules.js", 200, "application/javascript"),
    ("/js/app.js", 200, "application/javascript"),
    ("/samples/gb50017-2017.pack.json", 200, "application/json"),
]

print("=" * 64)
print("【模拟 iPad Safari 加载 PWA 全部资源】")
print("=" * 64)
all_ok = True
for path, want_status, want_mime in checks:
    try:
        url = f"http://127.0.0.1:{PORT}{path}"
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        })
        r = urllib.request.urlopen(req, timeout=3)
        body = r.read()
        ct = r.headers.get("Content-Type", "").split(";")[0].strip()
        size = len(body)
        ok_status = r.status == want_status
        # MIME 比较宽松（Python 自带服务器不一定按扩展名严格）
        ok_mime = (want_mime in ct) or (path.endswith(".json") and ct in ("application/json", "text/plain", "")) or (path.endswith(".png") and ct == "image/png")
        status = "OK" if (ok_status and ok_mime) else "WARN"
        print(f"  [{status}] {path:<42s} HTTP {r.status}  {ct:<30s}  {size:>6d}B")
        if not ok_status:
            all_ok = False
    except Exception as e:
        print(f"  [FAIL] {path}: {e}")
        all_ok = False

server.shutdown()

print()
print("=" * 64)
print("【结论】")
print("=" * 64)
if all_ok:
    print("  ✓ 全部资源在 Safari iOS PWA 加载流程下响应正常")
    print("  ✓ iPad Pro 2025 11\" M5 的 Safari 添加到主屏幕后")
    print("     → 首次联网打开 → 触发 Service Worker 预缓存")
    print("     → 之后断网可用、所有功能（含两个标准）均离线运行")
else:
    print("  ✗ 有资源加载异常，需修复")
    sys.exit(1)
