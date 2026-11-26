from __future__ import annotations

import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import uvicorn

from server import DATA_DIR, PORT, TUNNEL_URL_PATH, app, ensure_dirs_and_icons, get_lan_ip

BASE_DIR = Path(__file__).resolve().parent


def tunnel_worker() -> None:
    url_re = re.compile(r"https://[a-zA-Z0-9.-]+\.lhr\.life")
    while True:
        try:
            proc = subprocess.Popen(
                [
                    "ssh",
                    "-T",
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    "-o",
                    "ServerAliveInterval=30",
                    "-o",
                    "ServerAliveCountMax=3",
                    "-o",
                    "ExitOnForwardFailure=yes",
                    "-R",
                    f"80:127.0.0.1:{PORT}",
                    "nokey@localhost.run",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                m = url_re.search(line)
                if m:
                    url = m.group(0)
                    TUNNEL_URL_PATH.write_text(url, encoding="utf-8")
                    print(f"\n[HTTPS iPhone - Moi mang Wi-Fi/4G]: {url}", flush=True)
                    print(
                        "  -> Mo link tren bang Safari iPhone -> Chia se -> Them vao Man hinh chinh\n",
                        flush=True,
                    )
            proc.wait()
        except Exception as exc:
            print(f"[tunnel] {exc}", flush=True)
        time.sleep(3)


def main() -> None:
    ensure_dirs_and_icons()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if TUNNEL_URL_PATH.exists():
        TUNNEL_URL_PATH.unlink(missing_ok=True)

    lan_ip = get_lan_ip()
    print("=" * 64, flush=True)
    print("  YOUTUBE CA NHAN CHO IPHONE (PHAT NEN KHI TAT MAN HINH)", flush=True)
    print("=" * 64, flush=True)
    print(f"[LAN Wi-Fi cung mang]: http://{lan_ip}:{PORT}", flush=True)
    print("[Dang khoi tao cong HTTPS tu dong cho iPhone...]", flush=True)

    if "--no-tunnel" not in sys.argv:
        t = threading.Thread(target=tunnel_worker, daemon=True)
        t.start()

    uvicorn.run("server:app", host="0.0.0.0", port=PORT, reload=True, log_level="warning")


if __name__ == "__main__":
    main()
