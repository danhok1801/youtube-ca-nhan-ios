from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import socket
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx
import yt_dlp
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageDraw

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
ICONS_DIR = STATIC_DIR / "icons"
DATA_DIR = BASE_DIR / "data"
PROFILE_PATH = DATA_DIR / "profile.json"
GOOGLE_AUTH_PATH = DATA_DIR / "google_auth.json"
TUNNEL_URL_PATH = DATA_DIR / "tunnel_url.txt"

TV_CLIENT_ID_DEFAULT = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
TV_CLIENT_SECRET_DEFAULT = "SboVhoG9s0rNafixCSGGKXAT"
TV_OAUTH_SCOPE = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"

PORT = int(os.environ.get("PORT", "8899"))
APP_PIN = os.environ.get("APP_PIN", "").strip()
APP_PIN_TOKEN = hashlib.sha256(f"yt-pin:{APP_PIN}".encode()).hexdigest() if APP_PIN else ""
STREAM_TTL_SECONDS = 3 * 3600  # googlevideo URLs expire in ~6h; refresh after 3h
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

INNERTUBE_CONTEXT = {
    "context": {
        "client": {
            "clientName": "WEB",
            "clientVersion": "2.20261120.01.00",
            "hl": "vi",
            "gl": "VN",
            "timeZone": "Asia/Ho_Chi_Minh",
            "utcOffsetMinutes": 420,
        }
    }
}

CATEGORY_QUERIES: dict[str, str] = {
    "all": "xu hướng việt nam hot nhất hôm nay",
    "music": "nhạc trẻ việt nam hot nhất hiện nay official mv",
    "remix": "nhạc trẻ remix hay nhất hiện nay nonstop",
    "lofi": "lofi chill tiếng việt nhẹ nhàng dễ ngủ",
    "podcast": "podcast tiếng việt hay nhất tâm lý phát triển bản thân",
    "gaming": "gaming việt nam highlight mới nhất",
    "news": "tin tức thời sự việt nam mới nhất hôm nay",
    "comedy": "hài kịch việt nam mới nhất triệu view",
    "tech": "đánh giá công nghệ iphone mới nhất",
    "live": "nhạc chill trực tiếp 24/7 lofi hip hop",
}

_executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="ytdlp")
_stream_cache: dict[str, dict[str, Any]] = {}
_inflight: dict[str, asyncio.Future[dict[str, Any]]] = {}
_feed_cache: dict[str, tuple[float, Any]] = {}
_sponsor_cache: dict[str, list[dict[str, Any]]] = {}
_pending_device: dict[str, Any] = {}

AD_NODE_KEYS = frozenset(
    {
        "adSlotRenderer",
        "adBadgeViewModel",
        "promotedSparklesWebRenderer",
        "promotedVideoRenderer",
        "searchPyvRenderer",
        "adPlacementRenderer",
        "inFeedAdLayoutRenderer",
        "playerAds",
        "adBreakHeartbeatParams",
    }
)

http_client: httpx.AsyncClient | None = None
stream_client: httpx.AsyncClient | None = None


def ensure_dirs_and_icons() -> None:
    ICONS_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not GOOGLE_AUTH_PATH.exists() and os.environ.get("GOOGLE_AUTH_JSON"):
        GOOGLE_AUTH_PATH.write_text(os.environ["GOOGLE_AUTH_JSON"], encoding="utf-8")

    if not PROFILE_PATH.exists():
        PROFILE_PATH.write_text(
            json.dumps(
                {
                    "history": [],
                    "liked": [],
                    "watchLater": [],
                    "subscriptions": [],
                    "playlists": [],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

    targets = [
        (ICONS_DIR / "apple-touch-icon.png", 180),
        (ICONS_DIR / "icon-192.png", 192),
        (ICONS_DIR / "icon-512.png", 512),
    ]
    for out_path, size in targets:
        if out_path.exists():
            continue
        scale = 4
        canvas_sz = size * scale
        img = Image.new("RGBA", (canvas_sz, canvas_sz), (15, 15, 15, 255))
        draw = ImageDraw.Draw(img)

        # Subtle dark surface border
        pad = int(canvas_sz * 0.14)
        rect_w = canvas_sz - pad * 2
        rect_h = int(rect_w * 0.72)
        top_y = (canvas_sz - rect_h) // 2
        radius = int(rect_h * 0.28)
        draw.rounded_rectangle(
            [pad, top_y, pad + rect_w, top_y + rect_h],
            radius=radius,
            fill=(255, 0, 51, 255),
        )

        # Crisp white play triangle
        tri_w = int(rect_w * 0.30)
        tri_h = int(rect_h * 0.44)
        cx = canvas_sz // 2 + int(canvas_sz * 0.02)
        cy = canvas_sz // 2
        pts = [
            (cx - tri_w // 2, cy - tri_h // 2),
            (cx - tri_w // 2, cy + tri_h // 2),
            (cx + tri_w // 2 + int(tri_w * 0.12), cy),
        ]
        draw.polygon(pts, fill=(255, 255, 255, 255))

        img = img.resize((size, size), Image.Resampling.LANCZOS)
        img.save(out_path, format="PNG")


def get_lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def load_profile() -> dict[str, Any]:
    try:
        return json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {"history": [], "liked": [], "watchLater": [], "subscriptions": [], "playlists": []}


def save_profile(data: dict[str, Any]) -> None:
    tmp = PROFILE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(PROFILE_PATH)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global http_client, stream_client
    ensure_dirs_and_icons()
    transport_v4 = httpx.AsyncHTTPTransport(local_address="0.0.0.0", retries=1)
    stream_transport_v4 = httpx.AsyncHTTPTransport(local_address="0.0.0.0", retries=1)
    http_client = httpx.AsyncClient(
        transport=transport_v4,
        headers={"User-Agent": USER_AGENT, "Accept-Language": "vi-VN,vi;q=0.9,en;q=0.8"},
        timeout=httpx.Timeout(12.0, connect=6.0),
        follow_redirects=True,
    )
    stream_client = httpx.AsyncClient(
        transport=stream_transport_v4,
        headers={"User-Agent": USER_AGENT},
        timeout=httpx.Timeout(30.0, connect=8.0, read=25.0),
        follow_redirects=True,
        limits=httpx.Limits(max_keepalive_connections=20, max_connections=60),
    )
    yield
    await http_client.aclose()
    await stream_client.aclose()


app = FastAPI(title="YouTube Personal iOS", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["Content-Range", "Accept-Ranges", "Content-Length", "Content-Type"],
)


@app.middleware("http")
async def pin_guard_middleware(request: Request, call_next):
    if APP_PIN and request.url.path.startswith("/api/") and not request.url.path.startswith("/api/pin/"):
        cookie_tok = request.cookies.get("yt_pin", "")
        header_tok = request.headers.get("x-app-pin", "")
        query_tok = request.query_params.get("pin", "")
        if APP_PIN_TOKEN not in (cookie_tok, header_tok, query_tok):
            return JSONResponse({"detail": "PIN_REQUIRED"}, status_code=401)
    return await call_next(request)


@app.get("/api/pin/check")
async def api_pin_check(request: Request) -> dict[str, Any]:
    if not APP_PIN:
        return {"required": False, "unlocked": True}
    unlocked = request.cookies.get("yt_pin", "") == APP_PIN_TOKEN
    return {"required": True, "unlocked": unlocked}


@app.post("/api/pin/unlock")
async def api_pin_unlock(request: Request) -> Response:
    body = await request.json()
    entered = str(body.get("pin") or "").strip()
    if APP_PIN and entered != APP_PIN:
        return JSONResponse({"ok": False, "detail": "Sai mã khóa"}, status_code=403)
    resp = JSONResponse({"ok": True, "token": APP_PIN_TOKEN})
    if APP_PIN_TOKEN:
        resp.set_cookie(
            key="yt_pin",
            value=APP_PIN_TOKEN,
            max_age=365 * 86400,
            httponly=True,
            samesite="lax",
        )
    return resp


# ---------------------------------------------------------------------------
# Helpers: InnerTube JSON parsing (videoRenderer + 2026 lockupViewModel)
# ---------------------------------------------------------------------------

def _runs_text(node: Any) -> str:
    if not isinstance(node, dict):
        return ""
    if "simpleText" in node:
        return str(node["simpleText"])
    if "content" in node:
        return str(node["content"])
    if "runs" in node and isinstance(node["runs"], list):
        return "".join(str(r.get("text", "")) for r in node["runs"] if isinstance(r, dict))
    return ""


def _best_thumb(video_id: str, sources: list[dict[str, Any]] | None = None) -> str:
    if sources:
        best = sources[-1].get("url", "")
        if best.startswith("//"):
            best = "https:" + best
        if best:
            return best
    return f"https://i.ytimg.com/vi/{video_id}/hq720.jpg"


def _parse_video_renderer(vr: dict[str, Any]) -> dict[str, Any] | None:
    vid = vr.get("videoId")
    if not vid or len(vid) != 11:
        return None
    title = _runs_text(vr.get("title"))
    if not title:
        return None
    duration = _runs_text(vr.get("lengthText"))
    is_live = not duration and any(
        b.get("metadataBadgeRenderer", {}).get("style") == "BADGE_STYLE_TYPE_LIVE_NOW"
        for b in vr.get("badges", [])
        if isinstance(b, dict)
    )
    views = _runs_text(vr.get("shortViewCountText")) or _runs_text(vr.get("viewCountText"))
    published = _runs_text(vr.get("publishedTimeText"))

    owner_runs = (vr.get("ownerText") or vr.get("longBylineText") or {}).get("runs") or []
    channel_name = owner_runs[0].get("text", "") if owner_runs else ""
    channel_id = ""
    if owner_runs:
        channel_id = (
            owner_runs[0]
            .get("navigationEndpoint", {})
            .get("browseEndpoint", {})
            .get("browseId", "")
        )

    ch_thumbs = (
        vr.get("channelThumbnailSupportedRenderers", {})
        .get("channelThumbnailWithLinkRenderer", {})
        .get("thumbnail", {})
        .get("thumbnails", [])
    )
    channel_avatar = ch_thumbs[-1].get("url", "") if ch_thumbs else ""
    thumbs = vr.get("thumbnail", {}).get("thumbnails", [])

    resume_pct = 0
    for ov in vr.get("thumbnailOverlays") or []:
        if isinstance(ov, dict) and "thumbnailOverlayResumePlaybackRenderer" in ov:
            resume_pct = int(
                ov["thumbnailOverlayResumePlaybackRenderer"].get("percentDurationWatched") or 0
            )
            break

    return {
        "id": vid,
        "title": title,
        "channel": channel_name or "YouTube",
        "channelId": channel_id,
        "channelAvatar": channel_avatar,
        "views": views,
        "published": published,
        "duration": "TRỰC TIẾP" if is_live else duration,
        "isLive": is_live,
        "resumePercent": resume_pct,
        "thumbnail": _best_thumb(vid, thumbs),
    }


def _parse_lockup_vm(lv: dict[str, Any]) -> dict[str, Any] | None:
    ctype = lv.get("contentType", "")
    if ctype and ctype not in ("LOCKUP_CONTENT_TYPE_VIDEO", "LOCKUP_CONTENT_TYPE_SHORT"):
        return None
    vid = lv.get("contentId") or (
        lv.get("rendererContext", {})
        .get("commandContext", {})
        .get("onTap", {})
        .get("innertubeCommand", {})
        .get("watchEndpoint", {})
        .get("videoId", "")
    )
    if not vid or len(vid) != 11:
        return None

    meta_vm = lv.get("metadata", {}).get("lockupMetadataViewModel", {})
    title = _runs_text(meta_vm.get("title"))
    if not title:
        return None

    # Duration badge & Resume progress bar
    duration = ""
    resume_pct = 0
    overlays = (
        lv.get("contentImage", {})
        .get("thumbnailViewModel", {})
        .get("overlays", [])
    )
    for ov in overlays:
        bot = ov.get("thumbnailBottomOverlayViewModel", {})
        pb = bot.get("progressBar", {}).get("thumbnailOverlayProgressBarViewModel", {})
        if pb.get("startPercent"):
            resume_pct = int(pb["startPercent"])
        badges = bot.get("badges", [])
        for b in badges:
            txt = b.get("thumbnailBadgeViewModel", {}).get("text", "")
            if txt:
                duration = txt
                break

    # Channel avatar & browseId
    dec_av = meta_vm.get("image", {}).get("decoratedAvatarViewModel", {})
    av_sources = (
        dec_av.get("avatar", {})
        .get("avatarViewModel", {})
        .get("image", {})
        .get("sources", [])
    )
    channel_avatar = av_sources[-1].get("url", "") if av_sources else ""
    channel_id = (
        dec_av.get("rendererContext", {})
        .get("commandContext", {})
        .get("onTap", {})
        .get("innertubeCommand", {})
        .get("browseEndpoint", {})
        .get("browseId", "")
    )

    rows = (
        meta_vm.get("metadata", {})
        .get("contentMetadataViewModel", {})
        .get("metadataRows", [])
    )
    channel_name = ""
    views = ""
    published = ""
    if rows:
        p0 = rows[0].get("metadataParts", [])
        if p0:
            channel_name = _runs_text(p0[0].get("text"))
    if len(rows) > 1:
        p1 = rows[1].get("metadataParts", [])
        if p1:
            views = _runs_text(p1[0].get("text"))
            if views and "lượt xem" not in views.lower() and not views.isalpha():
                views = f"{views} lượt xem"
        if len(p1) > 1:
            published = _runs_text(p1[1].get("text"))

    img_sources = (
        lv.get("contentImage", {})
        .get("thumbnailViewModel", {})
        .get("image", {})
        .get("sources", [])
    )
    is_live = "TRỰC TIẾP" in duration.upper() or "LIVE" in duration.upper()

    return {
        "id": vid,
        "title": title,
        "channel": channel_name or "YouTube",
        "channelId": channel_id,
        "channelAvatar": channel_avatar,
        "views": views,
        "published": published,
        "duration": duration,
        "isLive": is_live,
        "resumePercent": resume_pct,
        "thumbnail": _best_thumb(vid, img_sources),
    }


def _parse_tile_renderer(tr: dict[str, Any]) -> dict[str, Any] | None:
    if _has_ad_badge(tr.get("metadata") or {}) or "pagead" in json.dumps(tr.get("onSelectCommand") or {}):
        return None
    vid = tr.get("contentId") or (
        tr.get("onSelectCommand", {}).get("watchEndpoint", {}).get("videoId", "")
    )
    if not vid or len(vid) != 11:
        return None
    meta = tr.get("metadata", {}).get("tileMetadataRenderer", {})
    title = _runs_text(meta.get("title"))
    if not title:
        return None

    header = tr.get("header", {}).get("tileHeaderRenderer", {})
    thumbs = header.get("thumbnail", {}).get("thumbnails", [])
    duration = ""
    resume_pct = 0
    for ov in header.get("thumbnailOverlays") or []:
        if "thumbnailOverlayTimeStatusRenderer" in ov:
            duration = _runs_text(ov["thumbnailOverlayTimeStatusRenderer"].get("text"))
        if "thumbnailOverlayResumePlaybackRenderer" in ov:
            resume_pct = int(
                ov["thumbnailOverlayResumePlaybackRenderer"].get("percentDurationWatched") or 0
            )

    parts: list[str] = []
    for ln in meta.get("lines") or []:
        for item in ln.get("lineRenderer", {}).get("items") or []:
            txt = _runs_text(item.get("lineItemRenderer", {}).get("text"))
            if txt and txt != "•":
                parts.append(txt)

    return {
        "id": vid,
        "title": title,
        "channel": parts[0] if parts else "YouTube",
        "channelId": "",
        "channelAvatar": "",
        "views": parts[1] if len(parts) > 1 else "",
        "published": parts[2] if len(parts) > 2 else "",
        "duration": duration,
        "isLive": "TRỰC TIẾP" in duration.upper() or "LIVE" in duration.upper(),
        "resumePercent": resume_pct,
        "thumbnail": _best_thumb(vid, thumbs),
    }


def _has_ad_badge(node: Any) -> bool:
    raw = json.dumps(node, ensure_ascii=False)
    return (
        '"BADGE_STYLE_TYPE_AD"' in raw
        or '"adSlotRenderer"' in raw
        or '"Được tài trợ"' in raw
        or '"Quảng cáo"' in raw
    )


def extract_videos_from_tree(tree: Any, limit: int = 36) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    seen: set[str] = set()

    def walk(node: Any) -> None:
        if len(results) >= limit:
            return
        if isinstance(node, dict):
            if AD_NODE_KEYS.intersection(node.keys()):
                return
            if "videoRenderer" in node and isinstance(node["videoRenderer"], dict):
                vr = node["videoRenderer"]
                if _has_ad_badge(vr.get("badges") or []):
                    return
                item = _parse_video_renderer(vr)
                if item and item["id"] not in seen:
                    seen.add(item["id"])
                    results.append(item)
                return
            if "lockupViewModel" in node and isinstance(node["lockupViewModel"], dict):
                lv = node["lockupViewModel"]
                if _has_ad_badge(lv.get("metadata") or {}):
                    return
                item = _parse_lockup_vm(lv)
                if item and item["id"] not in seen:
                    seen.add(item["id"])
                    results.append(item)
                return
            if "tileRenderer" in node and isinstance(node["tileRenderer"], dict):
                item = _parse_tile_renderer(node["tileRenderer"])
                if item and item["id"] not in seen:
                    seen.add(item["id"])
                    results.append(item)
                return
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for elem in node:
                walk(elem)

    walk(tree)
    return results


def extract_channels_from_tree(tree: Any, limit: int = 5) -> list[dict[str, Any]]:
    channels: list[dict[str, Any]] = []
    seen: set[str] = set()

    def walk(node: Any) -> None:
        if len(channels) >= limit:
            return
        if isinstance(node, dict):
            cr = node.get("channelRenderer")
            if isinstance(cr, dict):
                cid = cr.get("channelId", "")
                title = _runs_text(cr.get("title"))
                if cid and title and cid not in seen:
                    seen.add(cid)
                    thumbs = cr.get("thumbnail", {}).get("thumbnails", [])
                    av = thumbs[-1].get("url", "") if thumbs else ""
                    if av.startswith("//"):
                        av = "https:" + av
                    subs = _runs_text(cr.get("videoCountText")) or _runs_text(cr.get("subscriberCountText"))
                    channels.append(
                        {
                            "channelId": cid,
                            "name": title,
                            "avatar": av,
                            "subscribers": subs,
                        }
                    )
                return
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for elem in node:
                walk(elem)

    walk(tree)
    return channels


async def innertube_post(endpoint: str, payload: dict[str, Any]) -> dict[str, Any]:
    assert http_client is not None
    body = {**INNERTUBE_CONTEXT, **payload}
    r = await http_client.post(f"https://www.youtube.com/youtubei/v1/{endpoint}?prettyPrint=false", json=body)
    r.raise_for_status()
    return r.json()


def parse_youtube_id(raw: str) -> str | None:
    raw = raw.strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", raw):
        return raw
    m = re.search(r"(?:v=|youtu\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})", raw)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Helpers: yt-dlp Stream Extraction with Deduplication & 3h Cache
# ---------------------------------------------------------------------------

def _extract_streams_sync(video_id: str) -> dict[str, Any]:
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "source_address": "0.0.0.0",
        "socket_timeout": 10,
    }
    url = f"https://www.youtube.com/watch?v={video_id}"
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

    formats = info.get("formats") or []
    req_headers = info.get("http_headers") or {"User-Agent": USER_AGENT}

    # 1. Best M4A AAC audio stream for iOS hardware decoder + lock-screen <audio>
    m4a_candidates = [
        f
        for f in formats
        if f.get("ext") == "m4a"
        and f.get("acodec") not in (None, "none")
        and f.get("vcodec") in (None, "none")
        and str(f.get("protocol", "")).startswith("http")
        and f.get("url")
    ]
    m4a_candidates.sort(key=lambda f: float(f.get("abr") or f.get("tbr") or 0), reverse=True)

    # Fallback audio if m4a missing
    any_audio = [
        f
        for f in formats
        if f.get("acodec") not in (None, "none")
        and str(f.get("protocol", "")).startswith("http")
        and f.get("url")
    ]
    any_audio.sort(key=lambda f: float(f.get("abr") or f.get("tbr") or 0), reverse=True)
    chosen_audio = (m4a_candidates or any_audio or [None])[0]

    # 2. Best H.264 (avc1) MP4 video-only streams by height (360, 480, 720, 1080)
    h264_videos: dict[int, dict[str, Any]] = {}
    for f in formats:
        if (
            f.get("ext") == "mp4"
            and str(f.get("vcodec") or "").startswith("avc1")
            and str(f.get("protocol", "")).startswith("http")
            and f.get("height")
            and f.get("url")
        ):
            h = int(f["height"])
            prev = h264_videos.get(h)
            if not prev or float(f.get("tbr") or 0) > float(prev.get("tbr") or 0):
                h264_videos[h] = f

    # Live HLS manifest fallback
    hls_formats = [
        f
        for f in formats
        if "m3u8" in str(f.get("protocol", "")) and f.get("url")
    ]
    hls_formats.sort(key=lambda f: int(f.get("height") or 0), reverse=True)
    hls_url = hls_formats[0]["url"] if hls_formats else info.get("manifest_url")

    return {
        "id": video_id,
        "title": info.get("title") or "",
        "channel": info.get("uploader") or info.get("channel") or "YouTube",
        "channelId": info.get("channel_id") or "",
        "durationSeconds": int(info.get("duration") or 0),
        "isLive": bool(info.get("is_live")),
        "thumbnail": f"https://i.ytimg.com/vi/{video_id}/hq720.jpg",
        "audio": {
            "url": chosen_audio["url"],
            "mime": "audio/mp4" if chosen_audio.get("ext") == "m4a" else "audio/webm",
            "filesize": chosen_audio.get("filesize") or chosen_audio.get("filesize_approx"),
            "headers": chosen_audio.get("http_headers") or req_headers,
        }
        if chosen_audio
        else None,
        "videos": {
            str(h): {
                "url": vf["url"],
                "mime": "video/mp4",
                "height": h,
                "filesize": vf.get("filesize") or vf.get("filesize_approx"),
                "headers": vf.get("http_headers") or req_headers,
            }
            for h, vf in sorted(h264_videos.items())
        },
        "qualities": sorted(h264_videos.keys()),
        "hlsUrl": hls_url,
        "expiresAt": time.time() + STREAM_TTL_SECONDS,
    }


async def _extract_streams_innertube_fast(video_id: str) -> dict[str, Any] | None:
    assert http_client is not None
    ios_ua = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
    payload = {
        "videoId": video_id,
        "context": {
            "client": {
                "clientName": "IOS",
                "clientVersion": "20.10.4",
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82",
                "hl": "vi",
                "gl": "VN",
            }
        },
    }
    r = await http_client.post(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        json=payload,
        headers={"User-Agent": ios_ua, "X-YouTube-Client-Name": "5"},
    )
    if r.status_code != 200:
        return None
    d = r.json()
    if d.get("playabilityStatus", {}).get("status") != "OK":
        return None

    sd = d.get("streamingData") or {}
    af = sd.get("adaptiveFormats") or []
    vd = d.get("videoDetails") or {}

    m4a = [
        f
        for f in af
        if "audio/mp4" in str(f.get("mimeType", "")) and f.get("url")
    ]
    m4a.sort(key=lambda f: int(f.get("bitrate") or 0), reverse=True)

    videos: dict[int, dict[str, Any]] = {}
    for f in af:
        mime = str(f.get("mimeType", ""))
        if "video/mp4" in mime and "avc1" in mime and f.get("height") and f.get("url"):
            h = int(f["height"])
            prev = videos.get(h)
            if not prev or int(f.get("bitrate") or 0) > int(prev.get("bitrate") or 0):
                videos[h] = f

    hls_url = sd.get("hlsManifestUrl")
    is_live = bool(vd.get("isLiveContent"))
    if not m4a and not (is_live and hls_url):
        return None

    req_headers = {"User-Agent": ios_ua}
    chosen_audio = m4a[0] if m4a else None
    return {
        "id": video_id,
        "title": vd.get("title") or "",
        "channel": vd.get("author") or "YouTube",
        "channelId": vd.get("channelId") or "",
        "durationSeconds": int(vd.get("lengthSeconds") or 0),
        "isLive": is_live,
        "thumbnail": f"https://i.ytimg.com/vi/{video_id}/hq720.jpg",
        "audio": {
            "url": chosen_audio["url"],
            "mime": "audio/mp4",
            "filesize": int(chosen_audio["contentLength"]) if chosen_audio.get("contentLength") else None,
            "headers": req_headers,
        }
        if chosen_audio
        else None,
        "videos": {
            str(h): {
                "url": vf["url"],
                "mime": "video/mp4",
                "height": h,
                "filesize": int(vf["contentLength"]) if vf.get("contentLength") else None,
                "headers": req_headers,
            }
            for h, vf in sorted(videos.items())
        },
        "qualities": sorted(videos.keys()),
        "hlsUrl": hls_url,
        "expiresAt": time.time() + STREAM_TTL_SECONDS,
    }


async def resolve_streams(video_id: str, force_refresh: bool = False) -> dict[str, Any]:
    now = time.time()
    cached = _stream_cache.get(video_id)
    if cached and not force_refresh and cached["expiresAt"] > now:
        return cached

    fut = _inflight.get(video_id)
    if fut is not None and not force_refresh:
        return await fut

    loop = asyncio.get_running_loop()
    fut = loop.create_future()
    _inflight[video_id] = fut
    try:
        fast = await _extract_streams_innertube_fast(video_id)
        data = fast if fast is not None else await loop.run_in_executor(_executor, _extract_streams_sync, video_id)
        _stream_cache[video_id] = data
        fut.set_result(data)
        return data
    except Exception as exc:
        fut.set_exception(exc)
        raise
    finally:
        _inflight.pop(video_id, None)


# ---------------------------------------------------------------------------
# API Routes
# ---------------------------------------------------------------------------

@app.get("/api/info")
async def api_info() -> dict[str, Any]:
    lan_ip = get_lan_ip()
    tunnel_url = ""
    if TUNNEL_URL_PATH.exists():
        tunnel_url = TUNNEL_URL_PATH.read_text(encoding="utf-8").strip()
    return {
        "lanUrl": f"http://{lan_ip}:{PORT}",
        "tunnelUrl": tunnel_url,
        "port": PORT,
    }


@app.get("/api/suggest")
async def api_suggest(q: str = Query("", min_length=0)) -> list[str]:
    q = q.strip()
    if not q:
        return []
    assert http_client is not None
    try:
        url = (
            "https://suggestqueries-clients6.youtube.com/complete/search"
            f"?client=youtube&hl=vi&gl=VN&ds=yt&q={quote(q)}"
        )
        r = await http_client.get(url)
        text = r.text
        start = text.find("(")
        end = text.rfind(")")
        if start != -1 and end != -1:
            arr = json.loads(text[start + 1 : end])
            return [str(item[0]) for item in arr[1][:10] if isinstance(item, list) and item]
    except Exception:
        pass
    return []


@app.get("/api/home")
async def api_home(category: str = Query("all")) -> dict[str, Any]:
    cache_key = f"home:{category}"
    now = time.time()
    if category != "all" and cache_key in _feed_cache:
        ts, cached_items = _feed_cache[cache_key]
        if now - ts < 300:
            return {"items": cached_items, "category": category}

    profile = load_profile()
    tasks: list[asyncio.Task[Any]] = []

    if category == "all":
        token = await get_valid_google_token()
        if token:
            tasks.append(
                asyncio.create_task(
                    innertube_auth_post("browse", {"browseId": "FEwhat_to_watch"}, token=token)
                )
            )
            tasks.append(
                asyncio.create_task(
                    innertube_auth_post("browse", {"browseId": "default"}, token=token)
                )
            )
        else:
            # Blend personalized related videos from watch/liked history + Vietnam hot feeds
            seed_ids: list[str] = []
            for entry in (profile.get("history") or [])[:2] + (profile.get("liked") or [])[:1]:
                if isinstance(entry, dict) and entry.get("id") and entry["id"] not in seed_ids:
                    seed_ids.append(entry["id"])

            for sid in seed_ids[:2]:
                tasks.append(asyncio.create_task(innertube_post("next", {"videoId": sid})))

            tasks.append(
                asyncio.create_task(
                    innertube_post("search", {"query": "nhạc trẻ việt nam hot nhất 2026 mv"})
                )
            )
            tasks.append(
                asyncio.create_task(
                    innertube_post("search", {"query": "video xu hướng việt nam mới nhất hôm nay"})
                )
            )
    else:
        q = CATEGORY_QUERIES.get(category, category)
        tasks.append(asyncio.create_task(innertube_post("search", {"query": q})))

    responses = await asyncio.gather(*tasks, return_exceptions=True)
    merged: list[dict[str, Any]] = []
    seen: set[str] = set()
    lists: list[list[dict[str, Any]]] = []
    for resp in responses:
        if isinstance(resp, dict):
            lists.append(extract_videos_from_tree(resp, limit=20))

    # Interleave sources so Home feels varied and personalized
    max_len = max((len(lst) for lst in lists), default=0)
    for i in range(max_len):
        for lst in lists:
            if i < len(lst):
                v = lst[i]
                if v["id"] not in seen:
                    seen.add(v["id"])
                    merged.append(v)

    # Fallback if a signed-in Google account has empty watch history on FEwhat_to_watch
    if category == "all" and len(merged) < 6:
        fb1, fb2 = await asyncio.gather(
            innertube_post("search", {"query": "nhạc trẻ việt nam hot nhất 2026 mv"}),
            innertube_post("search", {"query": "video xu hướng việt nam mới nhất hôm nay"}),
            return_exceptions=True,
        )
        for fb in (fb1, fb2):
            if isinstance(fb, dict):
                for v in extract_videos_from_tree(fb, limit=18):
                    if v["id"] not in seen:
                        seen.add(v["id"])
                        merged.append(v)

    if category != "all" and merged:
        _feed_cache[cache_key] = (now, merged)
    return {"items": merged[:36], "category": category}


@app.get("/api/shorts")
async def api_shorts() -> dict[str, Any]:
    now = time.time()
    if "shorts" in _feed_cache and now - _feed_cache["shorts"][0] < 300:
        return {"items": _feed_cache["shorts"][1]}

    res1, res2 = await asyncio.gather(
        innertube_post("search", {"query": "#shorts xu hướng việt nam hài âm nhạc"}),
        innertube_post("search", {"query": "#shorts nhạc trẻ remix hot trend"}),
        return_exceptions=True,
    )
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for r in (res1, res2):
        if isinstance(r, dict):
            for v in extract_videos_from_tree(r, limit=20):
                if v["id"] not in seen:
                    seen.add(v["id"])
                    items.append(v)
    if items:
        _feed_cache["shorts"] = (now, items)
    return {"items": items[:24]}


@app.get("/api/search")
async def api_search(q: str = Query(..., min_length=1)) -> dict[str, Any]:
    q = q.strip()
    direct_id = parse_youtube_id(q)
    if direct_id:
        data = await resolve_streams(direct_id)
        dur = data["durationSeconds"]
        dur_txt = f"{dur // 60}:{dur % 60:02d}" if dur else ""
        return {
            "directVideoId": direct_id,
            "channels": [],
            "items": [
                {
                    "id": direct_id,
                    "title": data["title"],
                    "channel": data["channel"],
                    "channelId": data["channelId"],
                    "channelAvatar": "",
                    "views": "",
                    "published": "",
                    "duration": dur_txt,
                    "isLive": data["isLive"],
                    "thumbnail": data["thumbnail"],
                }
            ],
        }

    tree = await innertube_post("search", {"query": q})
    videos = extract_videos_from_tree(tree, limit=30)
    channels = extract_channels_from_tree(tree, limit=4)
    return {"directVideoId": None, "channels": channels, "items": videos}


def _find_first(node: Any, key: str) -> dict[str, Any] | None:
    if isinstance(node, dict):
        if key in node and isinstance(node[key], dict):
            return node[key]
        for v in node.values():
            found = _find_first(v, key)
            if found is not None:
                return found
    elif isinstance(node, list):
        for elem in node:
            found = _find_first(elem, key)
            if found is not None:
                return found
    return None


async def fetch_sponsor_segments(video_id: str) -> list[dict[str, Any]]:
    if video_id in _sponsor_cache:
        return _sponsor_cache[video_id]
    assert http_client is not None
    segs: list[dict[str, Any]] = []
    try:
        r = await http_client.get(
            "https://sponsor.ajay.app/api/skipSegments",
            params={
                "videoID": video_id,
                "categories": json.dumps(
                    ["sponsor", "selfpromo", "interaction", "music_offtopic"]
                ),
            },
            timeout=2.6,
        )
        if r.status_code == 200:
            for row in r.json():
                pair = row.get("segment") or []
                if len(pair) == 2 and float(pair[1]) - float(pair[0]) >= 1.0:
                    segs.append(
                        {
                            "start": round(float(pair[0]), 2),
                            "end": round(float(pair[1]), 2),
                            "category": str(row.get("category") or "sponsor"),
                        }
                    )
    except Exception:
        pass
    _sponsor_cache[video_id] = segs
    return segs


@app.get("/api/watch/{video_id}")
async def api_watch(video_id: str) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise HTTPException(status_code=400, detail="Mã video không hợp lệ")

    next_task = asyncio.create_task(innertube_post("next", {"videoId": video_id}))
    stream_task = asyncio.create_task(resolve_streams(video_id))
    sponsor_task = asyncio.create_task(fetch_sponsor_segments(video_id))

    next_data, stream_data, sponsor_segs = await asyncio.gather(
        next_task, stream_task, sponsor_task, return_exceptions=True
    )
    if isinstance(stream_data, Exception):
        raise HTTPException(status_code=502, detail=f"Không lấy được luồng phát: {stream_data}")
    if isinstance(sponsor_segs, Exception):
        sponsor_segs = []

    title = stream_data["title"]
    channel = stream_data["channel"]
    channel_id = stream_data["channelId"]
    channel_avatar = ""
    subscribers = ""
    views = ""
    published = ""
    description = ""
    related: list[dict[str, Any]] = []

    if isinstance(next_data, dict):
        p1 = _find_first(next_data, "videoPrimaryInfoRenderer") or {}
        p2 = _find_first(next_data, "videoSecondaryInfoRenderer") or {}

        title = _runs_text(p1.get("title")) or title
        vc = p1.get("viewCount", {}).get("videoViewCountRenderer", {})
        views = _runs_text(vc.get("shortViewCount")) or _runs_text(vc.get("viewCount"))
        published = _runs_text(p1.get("relativeDateText")) or _runs_text(p1.get("dateText"))

        owner = p2.get("owner", {}).get("videoOwnerRenderer", {})
        channel = _runs_text(owner.get("title")) or channel
        channel_id = (
            owner.get("navigationEndpoint", {}).get("browseEndpoint", {}).get("browseId")
            or channel_id
        )
        av_thumbs = owner.get("thumbnail", {}).get("thumbnails", [])
        if av_thumbs:
            channel_avatar = av_thumbs[-1].get("url", "")
        subscribers = _runs_text(owner.get("subscriberCountText"))
        description = (
            p2.get("attributedDescription", {}).get("content", "")
            or _runs_text(p2.get("description"))
        )
        related = [v for v in extract_videos_from_tree(next_data, limit=24) if v["id"] != video_id]

    # Pre-warm top Up-Next video in the background so locked-screen auto-next is instant (<30ms)
    if related:
        first_next_id = related[0]["id"]
        if first_next_id not in _stream_cache:
            asyncio.create_task(_safe_prefetch(first_next_id))

    return {
        "id": video_id,
        "title": title,
        "channel": channel,
        "channelId": channel_id,
        "channelAvatar": channel_avatar,
        "subscribers": subscribers,
        "views": views,
        "published": published,
        "description": description,
        "durationSeconds": stream_data["durationSeconds"],
        "isLive": stream_data["isLive"],
        "thumbnail": stream_data["thumbnail"],
        "qualities": stream_data["qualities"],
        "hlsUrl": stream_data["hlsUrl"] if stream_data["isLive"] else None,
        "sponsorSegments": sponsor_segs,
        "related": related,
    }


async def _safe_prefetch(video_id: str) -> None:
    try:
        await asyncio.gather(resolve_streams(video_id), fetch_sponsor_segments(video_id))
    except Exception:
        pass


@app.get("/api/prefetch/{video_id}")
async def api_prefetch(video_id: str) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        return {"ok": False}
    try:
        data, segs = await asyncio.gather(
            resolve_streams(video_id), fetch_sponsor_segments(video_id)
        )
        return {
            "ok": True,
            "id": video_id,
            "durationSeconds": data["durationSeconds"],
            "sponsorSegments": segs,
        }
    except Exception:
        return {"ok": False}


@app.get("/api/channel/{browse_id}")
async def api_channel(browse_id: str) -> dict[str, Any]:
    tree = await innertube_post("browse", {"browseId": browse_id})
    header = _find_first(tree, "pageHeaderViewModel") or {}
    name = _runs_text(header.get("title", {}).get("dynamicTextViewModel", {}).get("text"))
    av_sources = (
        header.get("image", {})
        .get("decoratedAvatarViewModel", {})
        .get("avatar", {})
        .get("avatarViewModel", {})
        .get("image", {})
        .get("sources", [])
    )
    avatar = av_sources[-1].get("url", "") if av_sources else ""
    banner_sources = (
        header.get("banner", {})
        .get("imageBannerViewModel", {})
        .get("image", {})
        .get("sources", [])
    )
    banner = banner_sources[-1].get("url", "") if banner_sources else ""

    videos = extract_videos_from_tree(tree, limit=30)
    if len(videos) < 6 and name:
        search_tree = await innertube_post("search", {"query": name})
        seen = {v["id"] for v in videos}
        for v in extract_videos_from_tree(search_tree, limit=20):
            if v["id"] not in seen:
                videos.append(v)

    return {
        "channelId": browse_id,
        "name": name or "Kênh YouTube",
        "avatar": avatar,
        "banner": banner,
        "items": videos,
    }


# ---------------------------------------------------------------------------
# Personal Profile Sync (History / Liked / Watch Later / Subscriptions)
# ---------------------------------------------------------------------------

@app.get("/api/profile")
async def api_get_profile() -> dict[str, Any]:
    return load_profile()


@app.post("/api/profile")
async def api_save_profile(request: Request) -> dict[str, Any]:
    body = await request.json()
    current = load_profile()
    for k in ("history", "liked", "watchLater", "subscriptions", "playlists"):
        if k in body and isinstance(body[k], list):
            current[k] = body[k][:300]
    save_profile(current)
    return {"ok": True}


# ---------------------------------------------------------------------------
# Google / Gmail Account OAuth2 Device Flow & Real Watch History Sync
# ---------------------------------------------------------------------------

def load_google_auth() -> dict[str, Any] | None:
    if not GOOGLE_AUTH_PATH.exists():
        return None
    try:
        data = json.loads(GOOGLE_AUTH_PATH.read_text(encoding="utf-8"))
        return data if data.get("refresh_token") or data.get("access_token") else None
    except Exception:
        return None


def save_google_auth(data: dict[str, Any]) -> None:
    tmp = GOOGLE_AUTH_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(GOOGLE_AUTH_PATH)


async def _discover_tv_creds() -> tuple[str, str]:
    assert http_client is not None
    try:
        tv_ua = {
            "User-Agent": (
                "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 "
                "(KHTML, like Gecko) SamsungBrowser/5.0 TV Safari/537.36"
            )
        }
        r = await http_client.get("https://www.youtube.com/tv", headers=tv_ua)
        scripts = re.findall(r'src="([^"]+)"', r.text)
        for s in scripts:
            if "kabuki" in s or "tv-player" in s or "base" in s:
                js_url = s if s.startswith("http") else f"https://www.youtube.com{s}"
                js = (await http_client.get(js_url, headers=tv_ua)).text
                m = re.search(
                    r'clientId:"([0-9]+-[a-zA-Z0-9_-]+\.apps\.googleusercontent\.com)",[a-zA-Z0-9_$]+:"([a-zA-Z0-9_-]{16,40})"',
                    js,
                )
                if m:
                    return m.group(1), m.group(2)
    except Exception:
        pass
    return TV_CLIENT_ID_DEFAULT, TV_CLIENT_SECRET_DEFAULT


async def get_valid_google_token() -> str | None:
    auth = load_google_auth()
    if not auth:
        return None
    now = time.time()
    if auth.get("access_token") and float(auth.get("expires_at") or 0) > now + 60:
        return str(auth["access_token"])

    refresh_token = auth.get("refresh_token")
    if not refresh_token:
        return None

    assert http_client is not None
    cid = auth.get("client_id") or TV_CLIENT_ID_DEFAULT
    csec = auth.get("client_secret") or TV_CLIENT_SECRET_DEFAULT
    try:
        r = await http_client.post(
            "https://www.youtube.com/o/oauth2/token",
            json={
                "client_id": cid,
                "client_secret": csec,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        tok = r.json()
        if "access_token" in tok:
            auth["access_token"] = tok["access_token"]
            auth["expires_at"] = now + int(tok.get("expires_in") or 3500)
            save_google_auth(auth)
            return str(tok["access_token"])
    except Exception:
        pass
    return None


async def innertube_auth_post(
    endpoint: str, payload: dict[str, Any], token: str | None = None
) -> dict[str, Any]:
    assert http_client is not None
    tok = token or await get_valid_google_token()
    if not tok:
        raise HTTPException(status_code=401, detail="Chưa đăng nhập tài khoản Google")

    auth = load_google_auth() or {}
    page_id = (auth.get("account") or {}).get("pageId") or ""
    ctx: dict[str, Any] = {
        "client": {
            "clientName": "TVHTML5",
            "clientVersion": "7.20261120.16.00",
            "hl": "vi",
            "gl": "VN",
            "timeZone": "Asia/Ho_Chi_Minh",
            "utcOffsetMinutes": 420,
        }
    }
    if page_id:
        ctx["user"] = {"onBehalfOfUser": page_id}

    r = await http_client.post(
        f"https://www.youtube.com/youtubei/v1/{endpoint}?prettyPrint=false",
        json={"context": ctx, **payload},
        headers={
            "Authorization": f"Bearer {tok}",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/tv",
        },
    )
    r.raise_for_status()
    return r.json()


async def fetch_google_accounts(access_token: str) -> list[dict[str, Any]]:
    accounts: list[dict[str, Any]] = []
    try:
        data = await innertube_auth_post(
            "account/accounts_list",
            {"accountReadMask": {"returnOwner": True}},
            token=access_token,
        )

        def walk(node: Any) -> None:
            if isinstance(node, dict):
                air = node.get("accountItemRenderer")
                if isinstance(air, dict):
                    name = _runs_text(air.get("accountName"))
                    byline = _runs_text(air.get("accountByline"))
                    thumbs = air.get("accountPhoto", {}).get("thumbnails", [])
                    avatar = thumbs[-1].get("url", "") if thumbs else ""
                    page_id = ""
                    tokens = (
                        air.get("serviceEndpoint", {})
                        .get("selectActiveIdentityEndpoint", {})
                        .get("supportedTokens", [])
                    )
                    for t in tokens:
                        if isinstance(t, dict) and "pageIdToken" in t:
                            page_id = str(t["pageIdToken"].get("pageId") or "")
                    if name:
                        accounts.append(
                            {
                                "name": name,
                                "handle": byline,
                                "avatar": avatar,
                                "pageId": page_id,
                                "isSelected": bool(air.get("isSelected")),
                            }
                        )
                    return
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for x in node:
                    walk(x)

        walk(data)
    except Exception:
        pass
    return accounts


@app.get("/api/auth/status")
async def api_auth_status() -> dict[str, Any]:
    tok = await get_valid_google_token()
    auth = load_google_auth()
    if not tok or not auth:
        return {"loggedIn": False, "account": None, "accounts": []}
    return {
        "loggedIn": True,
        "account": auth.get("account"),
        "accounts": auth.get("accounts") or [],
    }


@app.post("/api/auth/device/start")
async def api_auth_device_start() -> dict[str, Any]:
    assert http_client is not None
    cid, csec = TV_CLIENT_ID_DEFAULT, TV_CLIENT_SECRET_DEFAULT
    payload = {
        "client_id": cid,
        "scope": TV_OAUTH_SCOPE,
        "device_id": str(uuid.uuid4()),
        "device_model": "ytlr::",
    }
    r = await http_client.post("https://www.youtube.com/o/oauth2/device/code", json=payload)
    if r.status_code != 200:
        cid, csec = await _discover_tv_creds()
        payload["client_id"] = cid
        r = await http_client.post("https://www.youtube.com/o/oauth2/device/code", json=payload)

    if r.status_code != 200:
        raise HTTPException(status_code=502, detail="Không khởi tạo được mã đăng nhập Google")

    data = r.json()
    _pending_device.clear()
    _pending_device.update(
        {
            "device_code": data["device_code"],
            "client_id": cid,
            "client_secret": csec,
            "expires_at": time.time() + int(data.get("expires_in") or 1800),
        }
    )
    return {
        "userCode": data["user_code"],
        "verificationUrl": data.get("verification_url") or "https://www.google.com/device",
        "expiresIn": int(data.get("expires_in") or 1800),
        "interval": int(data.get("interval") or 5),
    }


@app.post("/api/auth/device/poll")
async def api_auth_device_poll() -> dict[str, Any]:
    if not _pending_device or time.time() > float(_pending_device.get("expires_at") or 0):
        return {"status": "expired"}

    assert http_client is not None
    r = await http_client.post(
        "https://www.youtube.com/o/oauth2/token",
        json={
            "client_id": _pending_device["client_id"],
            "client_secret": _pending_device["client_secret"],
            "code": _pending_device["device_code"],
            "grant_type": "http://oauth.net/grant_type/device/1.0",
        },
    )
    data = r.json()
    err = data.get("error")
    if err in ("authorization_pending", "slow_down"):
        return {"status": "pending"}
    if err:
        return {"status": "error", "error": data.get("error_description") or err}

    access_token = data["access_token"]
    refresh_token = data.get("refresh_token") or ""
    expires_at = time.time() + int(data.get("expires_in") or 3500)

    # Temporarily save without pageId so fetch_google_accounts queries owner identity
    save_google_auth(
        {
            "access_token": access_token,
            "refresh_token": refresh_token,
            "expires_at": expires_at,
            "client_id": _pending_device["client_id"],
            "client_secret": _pending_device["client_secret"],
            "account": {"name": "Tài khoản Google", "handle": "", "avatar": "", "pageId": ""},
            "accounts": [],
        }
    )

    accounts = await fetch_google_accounts(access_token)
    selected = next((a for a in accounts if a.get("isSelected")), None) or (
        accounts[0] if accounts else {"name": "Tài khoản Google", "handle": "", "avatar": "", "pageId": ""}
    )

    auth_obj = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_at": expires_at,
        "client_id": _pending_device["client_id"],
        "client_secret": _pending_device["client_secret"],
        "account": selected,
        "accounts": accounts,
    }
    save_google_auth(auth_obj)
    _pending_device.clear()
    _feed_cache.clear()
    return {"status": "connected", "account": selected, "accounts": accounts}


@app.post("/api/auth/select-account")
async def api_auth_select_account(request: Request) -> dict[str, Any]:
    body = await request.json()
    page_id = str(body.get("pageId") or "")
    name = str(body.get("name") or "")
    auth = load_google_auth()
    if not auth:
        raise HTTPException(status_code=401, detail="Chưa đăng nhập")

    for acc in auth.get("accounts") or []:
        if acc.get("pageId") == page_id and (not name or acc.get("name") == name):
            auth["account"] = acc
            break
    save_google_auth(auth)
    _feed_cache.clear()
    return {"ok": True, "account": auth.get("account")}


@app.post("/api/auth/logout")
async def api_auth_logout() -> dict[str, Any]:
    if GOOGLE_AUTH_PATH.exists():
        GOOGLE_AUTH_PATH.unlink(missing_ok=True)
    _pending_device.clear()
    _feed_cache.clear()
    return {"ok": True}


@app.get("/api/account/history")
async def api_account_history() -> dict[str, Any]:
    local_hist = load_profile().get("history") or []
    token = await get_valid_google_token()
    if not token:
        return {"loggedIn": False, "items": local_hist}

    try:
        tree = await innertube_auth_post("browse", {"browseId": "FEhistory"}, token=token)
        remote_items = extract_videos_from_tree(tree, limit=60)
    except Exception:
        remote_items = []

    # Merge local progress overrides with Google account watch history
    local_map = {x["id"]: x for x in local_hist if isinstance(x, dict) and x.get("id")}
    merged: list[dict[str, Any]] = []
    seen: set[str] = set()

    for x in local_hist[:5]:
        if isinstance(x, dict) and x.get("id") and x["id"] not in seen:
            seen.add(x["id"])
            merged.append(x)

    for v in remote_items:
        vid = v["id"]
        if vid in seen:
            continue
        seen.add(vid)
        loc = local_map.get(vid)
        if loc and loc.get("progress") and loc.get("durationSeconds"):
            v["progress"] = loc["progress"]
            v["durationSeconds"] = loc["durationSeconds"]
        merged.append(v)

    return {"loggedIn": True, "items": merged}


@app.get("/api/account/liked")
async def api_account_liked() -> dict[str, Any]:
    local_liked = load_profile().get("liked") or []
    token = await get_valid_google_token()
    if not token:
        return {"loggedIn": False, "items": local_liked}

    remote_items: list[dict[str, Any]] = []
    for bid in ("VLLL", "FEliked_videos"):
        try:
            tree = await innertube_auth_post("browse", {"browseId": bid}, token=token)
            remote_items = extract_videos_from_tree(tree, limit=50)
            if remote_items:
                break
        except Exception:
            pass

    seen: set[str] = set()
    merged: list[dict[str, Any]] = []
    for v in local_liked + remote_items:
        if isinstance(v, dict) and v.get("id") and v["id"] not in seen:
            seen.add(v["id"])
            merged.append(v)
    return {"loggedIn": True, "items": merged}


@app.get("/api/account/subscriptions")
async def api_account_subscriptions() -> dict[str, Any]:
    token = await get_valid_google_token()
    if not token:
        return {"loggedIn": False, "items": []}
    try:
        tree = await innertube_auth_post("browse", {"browseId": "FEsubscriptions"}, token=token)
        items = extract_videos_from_tree(tree, limit=45)
        return {"loggedIn": True, "items": items}
    except Exception:
        return {"loggedIn": True, "items": []}


# ---------------------------------------------------------------------------
# RFC 7233 HTTP 206 Byte-Range Proxy for iOS WebKit <audio> & <video>
# ---------------------------------------------------------------------------

def _pick_target_stream(data: dict[str, Any], media_type: str, quality: int) -> dict[str, Any] | None:
    if media_type == "audio":
        return data.get("audio")
    videos: dict[str, dict[str, Any]] = data.get("videos") or {}
    if not videos:
        return data.get("audio")
    available = sorted(int(k) for k in videos.keys())
    below_or_eq = [h for h in available if h <= quality]
    chosen_h = below_or_eq[-1] if below_or_eq else available[0]
    return videos[str(chosen_h)]


@app.api_route("/api/stream/{video_id}", methods=["GET", "HEAD"])
async def api_stream(
    video_id: str,
    request: Request,
    type: str = Query("audio", pattern="^(audio|video)$"),
    q: int = Query(720),
):
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise HTTPException(status_code=400, detail="Invalid video id")

    assert stream_client is not None
    data = await resolve_streams(video_id)

    # Live stream HLS redirect for native iOS Safari HLS player
    if data.get("isLive") and data.get("hlsUrl"):
        return RedirectResponse(data["hlsUrl"], status_code=302)

    target = _pick_target_stream(data, type, q)
    if not target:
        raise HTTPException(status_code=404, detail="Stream not found")

    range_header = request.headers.get("range")
    req_headers = dict(target.get("headers") or {})
    if range_header:
        req_headers["Range"] = range_header

    upstream_req = stream_client.build_request(
        request.method,
        target["url"],
        headers=req_headers,
    )
    upstream_resp = await stream_client.send(upstream_req, stream=True)

    # Auto re-extract once if cached googlevideo URL expired (403/410)
    if upstream_resp.status_code in (403, 410):
        await upstream_resp.aclose()
        data = await resolve_streams(video_id, force_refresh=True)
        target = _pick_target_stream(data, type, q)
        if not target:
            raise HTTPException(status_code=502, detail="Stream refresh failed")
        req_headers = dict(target.get("headers") or {})
        if range_header:
            req_headers["Range"] = range_header
        upstream_req = stream_client.build_request(request.method, target["url"], headers=req_headers)
        upstream_resp = await stream_client.send(upstream_req, stream=True)

    resp_headers: dict[str, str] = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-store",
        "Content-Type": upstream_resp.headers.get("content-type") or target["mime"],
    }
    for h in ("Content-Length", "Content-Range"):
        val = upstream_resp.headers.get(h)
        if val:
            resp_headers[h] = val

    status_code = upstream_resp.status_code
    if not range_header and status_code == 206 and "Content-Range" in resp_headers:
        # Keep 206 when Range bytes=0- was synthesized; iOS WebKit loves 206 + Content-Range
        pass

    if request.method == "HEAD":
        await upstream_resp.aclose()
        return Response(status_code=status_code, headers=resp_headers)

    async def byte_iterator():
        try:
            async for chunk in upstream_resp.aiter_bytes(chunk_size=65536):
                yield chunk
        except (httpx.StreamError, asyncio.CancelledError):
            pass
        finally:
            await upstream_resp.aclose()

    return StreamingResponse(
        byte_iterator(),
        status_code=status_code,
        headers=resp_headers,
        media_type=resp_headers["Content-Type"],
    )


# ---------------------------------------------------------------------------
# PWA & Static Routes
# ---------------------------------------------------------------------------

@app.get("/apple-touch-icon.png")
async def apple_touch_icon():
    return FileResponse(ICONS_DIR / "apple-touch-icon.png", media_type="image/png")


@app.get("/manifest.webmanifest")
async def web_manifest():
    return FileResponse(STATIC_DIR / "manifest.webmanifest", media_type="application/manifest+json")


@app.get("/sw.js")
async def service_worker():
    return FileResponse(
        STATIC_DIR / "sw.js",
        media_type="application/javascript",
        headers={"Cache-Control": "no-cache"},
    )


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/{full_path:path}")
async def spa_fallback(full_path: str):
    candidate = STATIC_DIR / full_path
    if full_path and candidate.is_file():
        return FileResponse(candidate)
    return FileResponse(
        STATIC_DIR / "index.html",
        headers={"Cache-Control": "no-cache"},
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
