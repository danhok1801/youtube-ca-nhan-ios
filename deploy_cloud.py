from __future__ import annotations

import secrets
import sys
from pathlib import Path

from huggingface_hub import HfApi

BASE_DIR = Path(__file__).resolve().parent
GOOGLE_AUTH_PATH = BASE_DIR / "data" / "google_auth.json"


def main() -> None:
    print("=" * 68)
    print("  TRIEN KHAI YOUTUBE CA NHAN LEN DAM MAY 24/7 (TAT PC VAN CHAY)")
    print("=" * 68)
    print("\nBuoc 1: Lay ma Token mien phi (1 lan duy nhat):")
    print("  1. Mo https://huggingface.co/settings/tokens (dang ky mien phi neu chua co)")
    print("  2. Bam 'Create new token' -> Chon loai 'Write' -> Copy ma bat dau bang hf_...\n")

    token = input("Dan ma Token hf_... vao day roi nhan Enter: ").strip()
    if not token.startswith("hf_"):
        print("Ma token khong hop le (phai bat dau bang hf_).")
        sys.exit(1)

    pin = input("Dat ma PIN bao ve app cua rieng ban (4-6 so, Enter de bo qua): ").strip()

    api = HfApi(token=token)
    user_info = api.whoami()
    username = user_info["name"]
    suffix = secrets.token_hex(2)
    space_name = f"yt-iphone-{suffix}"
    repo_id = f"{username}/{space_name}"

    print(f"\n[*] Dang khoi tao may chu Docker 24/7: {repo_id} ...")
    api.create_repo(
        repo_id=repo_id,
        repo_type="space",
        space_sdk="docker",
        private=False,
        exist_ok=True,
    )

    if pin:
        api.add_space_secret(repo_id=repo_id, key="APP_PIN", value=pin)
    if GOOGLE_AUTH_PATH.exists():
        api.add_space_secret(
            repo_id=repo_id,
            key="GOOGLE_AUTH_JSON",
            value=GOOGLE_AUTH_PATH.read_text(encoding="utf-8"),
        )

    readme_md = (
        "---\n"
        "title: YouTube Personal\n"
        "emoji: ▶️\n"
        "colorFrom: red\n"
        "colorTo: gray\n"
        "sdk: docker\n"
        "app_port: 7860\n"
        "---\n"
    )
    api.upload_file(
        path_or_fileobj=readme_md.encode("utf-8"),
        path_in_repo="README.md",
        repo_id=repo_id,
        repo_type="space",
    )

    for rel in [
        "Dockerfile",
        "requirements.txt",
        "server.py",
        "static/index.html",
        "static/styles.css",
        "static/app.js",
        "static/manifest.webmanifest",
        "static/sw.js",
    ]:
        local_p = BASE_DIR / rel
        if local_p.exists():
            api.upload_file(
                path_or_fileobj=str(local_p),
                path_in_repo=rel,
                repo_id=repo_id,
                repo_type="space",
            )

    direct_url = f"https://{username.lower()}-{space_name.lower()}.hf.space"
    (BASE_DIR / "data" / "cloud_url.txt").write_text(direct_url, encoding="utf-8")

    print("\n" + "=" * 68)
    print("  HOAN TAT! LINK CO DINH 24/7 CHO IPHONE CUA BAN (DOI ~2 PHUT BUILD):")
    print(f"  👉 {direct_url}")
    print("=" * 68)
    print("  Mo link tren bang Safari iPhone -> Chia se -> Them vao Man hinh chinh.")
    print("  Tu nay ban TAT HAN MAY TINH di app tren iPhone van chay 24/7!\n")


if __name__ == "__main__":
    main()
