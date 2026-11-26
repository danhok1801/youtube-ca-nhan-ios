from __future__ import annotations

import httpx

BASE = "http://127.0.0.1:8899"


def main() -> None:
    with httpx.Client(timeout=20.0, follow_redirects=True) as c:
        # 1. Static & PWA assets
        assert c.get(f"{BASE}/").status_code == 200
        assert c.get(f"{BASE}/manifest.webmanifest").json()["display"] == "standalone"
        icon = c.get(f"{BASE}/apple-touch-icon.png")
        assert icon.status_code == 200 and icon.headers["content-type"] == "image/png"

        # 2. Home & Search & Suggest
        home = c.get(f"{BASE}/api/home?category=all").json()
        assert len(home["items"]) >= 10, f"Expected >=10 home items, got {len(home['items'])}"

        sug = c.get(f"{BASE}/api/suggest?q=nhac").json()
        assert isinstance(sug, list) and len(sug) >= 3

        # 3. Watch + Up Next (2026 lockupViewModel) + SponsorBlock
        vid = home["items"][0]["id"]
        watch = c.get(f"{BASE}/api/watch/{vid}").json()
        assert watch["id"] == vid and watch["title"]
        assert "sponsorSegments" in watch and isinstance(watch["sponsorSegments"], list)
        assert len(watch["related"]) >= 5, "Up Next related list should not be empty"

        sb_watch = c.get(f"{BASE}/api/watch/hxwpkM5w3Cc").json()
        assert len(sb_watch["sponsorSegments"]) >= 1, "Expected SponsorBlock segments on known video"

        # 4. iOS WebKit RFC 7233 Byte-Range Audio & Video Probes
        ra = c.get(
            f"{BASE}/api/stream/{vid}?type=audio",
            headers={"Range": "bytes=0-1023"},
        )
        assert ra.status_code == 206, f"Expected 206 for audio Range, got {ra.status_code}"
        assert "audio/" in ra.headers.get("content-type", "")
        assert "bytes 0-1023/" in ra.headers.get("content-range", "")
        assert len(ra.content) == 1024

        rv = c.get(
            f"{BASE}/api/stream/{vid}?type=video&q=720",
            headers={"Range": "bytes=0-1023"},
        )
        assert rv.status_code == 206, f"Expected 206 for video Range, got {rv.status_code}"
        assert "video/mp4" in rv.headers.get("content-type", "")
        assert len(rv.content) == 1024

        # 5. Google OAuth2 Device Flow & Account History endpoints
        st = c.get(f"{BASE}/api/auth/status").json()
        assert "loggedIn" in st
        dev = c.post(f"{BASE}/api/auth/device/start").json()
        assert len(dev["userCode"]) >= 8 and "google.com/device" in dev["verificationUrl"]
        poll = c.post(f"{BASE}/api/auth/device/poll").json()
        assert poll["status"] == "pending"
        hist = c.get(f"{BASE}/api/account/history").json()
        assert "items" in hist and isinstance(hist["items"], list)

        # 6. Public HTTPS Tunnel reachability for iPhone
        info = c.get(f"{BASE}/api/info").json()
        if info.get("tunnelUrl"):
            rt = c.get(f"{info['tunnelUrl']}/manifest.webmanifest")
            assert rt.status_code == 200

        print("ALL E2E CHECKS PASSED:", {"videoTested": vid, "info": info})


if __name__ == "__main__":
    main()
