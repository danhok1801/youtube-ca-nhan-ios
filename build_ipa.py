from __future__ import annotations

import subprocess
import sys
import time
import webbrowser
from pathlib import Path

import httpx

BASE_DIR = Path(__file__).resolve().parent
OUT_IPA = BASE_DIR / "YouTubeCaNhan.ipa"


def run_git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(BASE_DIR),
        text=True,
        capture_output=True,
        check=check,
    )


def main() -> None:
    print("=" * 70)
    print("  TRINH TU DONG DONG GOI FILE .IPA CHO IPHONE (YOUTUBE CA NHAN)")
    print("=" * 70)
    print("\nCong cu nay se day ma nguon len GitHub cua ban de may Mac dam may")
    print("bien dich ra file 'YouTubeCaNhan.ipa' va tai thang ve thu muc nay.\n")

    print("Buoc 1: Tao 1 Token GitHub de tao kho va tai file .ipa tu dong:")
    print("  - Mo: https://github.com/settings/tokens/new?scopes=repo,workflow&description=YouTubeIPA")
    print("  - Keo xuong bam nut xanh 'Generate token' -> Copy ma ghp_...\n")

    open_tok = input("Bam Enter de mo trang lay Token GitHub tren trinh duyet (hoac go N de bo qua): ").strip()
    if open_tok.lower() != "n":
        webbrowser.open("https://github.com/settings/tokens/new?scopes=repo,workflow&description=YouTubeIPA")

    token = input("\nDan ma GitHub Token (ghp_... hoac github_pat_...) vao day: ").strip()
    if not token:
        print("Chua nhap token. Dung lai.")
        sys.exit(1)

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    with httpx.Client(headers=headers, timeout=25.0, follow_redirects=True) as client:
        me = client.get("https://api.github.com/user")
        if me.status_code != 200:
            print(f"Token khong hop le ({me.status_code}): {me.text}")
            sys.exit(1)
        username = me.json()["login"]
        repo_name = "youtube-ca-nhan-ios"
        full_repo = f"{username}/{repo_name}"

        print(f"\n[*] Dang chuan bi kho GitHub: {full_repo} ...")
        repo_check = client.get(f"https://api.github.com/repos/{full_repo}")
        if repo_check.status_code == 404:
            cr = client.post(
                "https://api.github.com/user/repos",
                json={
                    "name": repo_name,
                    "private": False,  # Public repo gets unlimited free macOS Actions minutes!
                    "description": "Standalone iOS YouTube Personal App Builder",
                },
            )
            if cr.status_code not in (200, 201):
                print(f"Khong tao duoc repo: {cr.text}")
                sys.exit(1)

        # Ensure git commit & push
        if not (BASE_DIR / ".git").exists():
            run_git("init")
        run_git("config", "user.name", username, check=False)
        run_git("config", "user.email", f"{username}@users.noreply.github.com", check=False)
        run_git("add", "-A")
        run_git("commit", "-m", "Build standalone iPhone YouTube IPA", check=False)
        run_git("branch", "-M", "main")

        push_url = f"https://{username}:{token}@github.com/{full_repo}.git"
        print("[*] Dang day ma nguon Swift iOS len may bien dich macOS...")
        push_res = run_git("push", "--force", push_url, "main", check=False)
        if push_res.returncode != 0:
            print("Loi khi push:", push_res.stderr)
            sys.exit(1)

        # Remove token from local git config if any remote was set
        run_git("remote", "remove", "origin", check=False)
        run_git("remote", "add", "origin", f"https://github.com/{full_repo}.git", check=False)

        print(f"[*] Da kich hoat bien dich Xcode tren GitHub Actions: https://github.com/{full_repo}/actions")
        print("[*] Dang cho may Mac bien dich file YouTubeCaNhan.ipa (thuong mat ~2-3 phut)...")

        time.sleep(8)
        start_wait = time.time()
        while time.time() - start_wait < 600:
            runs_resp = client.get(f"https://api.github.com/repos/{full_repo}/actions/runs?per_page=1")
            if runs_resp.status_code == 200:
                runs = runs_resp.json().get("workflow_runs") or []
                if runs:
                    run_info = runs[0]
                    st = run_info.get("status")
                    concl = run_info.get("conclusion")
                    elapsed = int(time.time() - start_wait)
                    print(f"    [{elapsed}s] Trang thai bien dich: {st} {concl or ''}", flush=True)
                    if st == "completed":
                        if concl != "success":
                            print(f"\n[!] Bien dich gap loi. Xem chi tiet tai: {run_info.get('html_url')}")
                            sys.exit(1)
                        break
            time.sleep(10)

        # Download YouTubeCaNhan.ipa from Release 'latest-ipa'
        print("\n[*] Bien dich THANH CONG! Dang tai YouTubeCaNhan.ipa ve may tinh...")
        rel_resp = client.get(f"https://api.github.com/repos/{full_repo}/releases/tags/latest-ipa")
        if rel_resp.status_code == 200:
            assets = rel_resp.json().get("assets") or []
            ipa_asset = next((a for a in assets if a["name"].endswith(".ipa")), None)
            if ipa_asset:
                dl = client.get(ipa_asset["browser_download_url"])
                OUT_IPA.write_bytes(dl.content)
                size_mb = round(len(dl.content) / (1024 * 1024), 2)
                print("\n" + "=" * 70)
                print(f"  DA TAI XONG FILE IPA ({size_mb} MB):")
                print(f"  👉 {OUT_IPA}")
                print("=" * 70)
                print("\nBuoc cuoi: Cai vao iPhone bang Sideloadly (https://sideloadly.io):")
                print("  1. Cam cap iPhone vao may tinh -> Mo Sideloadly -> Nhap Apple ID.")
                print("  2. Keo file D:\\LEFT\\Youtubeeee\\YouTubeCaNhan.ipa tha vao Sideloadly -> Bam Start.")
                print("  3. Tren iPhone: Cai dat -> Cai dat chung -> Quan ly VPN & Thiet bi -> Tin cay.")
                print("  4. Neu iOS 16/17/18 hoi Che do nha phat trien: Cai dat -> Quyen rieng tu & Bao mat -> Che do nha phat trien -> Bat.\n")
                return

        print(f"Tai thu cong tai: https://github.com/{full_repo}/releases")


if __name__ == "__main__":
    main()
