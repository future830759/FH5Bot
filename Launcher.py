# Launcher.py (UI + progress bar, no log file)
# Build:
#   python -m PyInstaller -F -w Launcher.py --name Launcher

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from queue import Queue, Empty
from typing import Optional, Dict, Tuple
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

import tkinter as tk
from tkinter import ttk, messagebox

# ========================
# 🔧 設定
# ========================
GITHUB_OWNER = "future830759"
GITHUB_REPO = "FH5Bot"

ASSET_PREFIX = "app_"
ASSET_SUFFIX = ".zip"

MANIFEST_NAME = "manifest.json"
FORCE_NO_USER_SITE = True

# ========================
# 📁 路徑
# ========================
EXE_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
APP_DIR = EXE_DIR / "app"
CURRENT_DIR = APP_DIR / "current"
BACKUP_DIR = APP_DIR / "backups"
CACHE_DIR = EXE_DIR / "cache"
DATA_DIR = EXE_DIR / "data"
LOCAL_VERSION_FILE = EXE_DIR / "version.txt"

# ========================
# GitHub / HTTP
# ========================
def _headers(json_api: bool = False) -> Dict[str, str]:
    h = {"User-Agent": "FH5Bot-Launcher"}
    if json_api:
        h["Accept"] = "application/vnd.github+json"
    return h


def http_get_json(url: str, timeout: int = 20) -> dict:
    req = Request(url, headers=_headers(True))
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def http_download_with_progress(url: str, dest: Path, progress_cb) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = Request(url, headers=_headers())
    with urlopen(req) as resp:
        total = resp.headers.get("Content-Length")
        total = int(total) if total and total.isdigit() else None
        tmp = dest.with_suffix(".part")
        downloaded = 0
        with tmp.open("wb") as f:
            while True:
                chunk = resp.read(1024 * 256)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                progress_cb(downloaded, total)
        tmp.replace(dest)

# ========================
# Release parsing
# ========================
@dataclass
class Asset:
    name: str
    url: str


@dataclass
class LatestRelease:
    tag: str
    assets: list[Asset]


def fetch_latest_release() -> LatestRelease:
    api = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"
    j = http_get_json(api)
    tag = j["tag_name"]
    assets = [Asset(a["name"], a["browser_download_url"]) for a in j.get("assets", [])]
    return LatestRelease(tag, assets)


def pick_asset(rel: LatestRelease) -> Asset:
    for a in rel.assets:
        if a.name.startswith(ASSET_PREFIX) and a.name.endswith(ASSET_SUFFIX):
            return a
    raise RuntimeError("找不到 app_*.zip")

# ========================
# App ops
# ========================
def ensure_dirs():
    for d in (APP_DIR, BACKUP_DIR, CACHE_DIR, DATA_DIR):
        d.mkdir(parents=True, exist_ok=True)


def read_local_version() -> str:
    return LOCAL_VERSION_FILE.read_text().strip() if LOCAL_VERSION_FILE.exists() else ""


def write_local_version(ver: str):
    LOCAL_VERSION_FILE.write_text(ver.strip(), encoding="utf-8")


def extract_zip(zip_path: Path, target_dir: Path):
    if target_dir.exists():
        shutil.rmtree(target_dir, ignore_errors=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(target_dir)


def atomic_switch(new_dir: Path):
    if CURRENT_DIR.exists():
        backup = BACKUP_DIR / f"current_{int(time.time())}"
        shutil.move(str(CURRENT_DIR), backup)
    shutil.move(str(new_dir), CURRENT_DIR)


def read_manifest() -> Tuple[Path, list[str]]:
    mf = CURRENT_DIR / MANIFEST_NAME
    cfg = json.loads(mf.read_text(encoding="utf-8"))
    return (CURRENT_DIR / cfg["entry"]).resolve(), cfg.get("args", [])


def launch_current():
    entry, args = read_manifest()
    env = os.environ.copy()
    if FORCE_NO_USER_SITE:
        env["PYTHONNOUSERSITE"] = "1"

    flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    subprocess.Popen(
        [str(entry), *args],
        cwd=str(CURRENT_DIR),
        env=env,
        creationflags=flags,
        close_fds=True,
    )

# ========================
# Worker
# ========================
def worker(q: Queue):
    try:
        ensure_dirs()
        q.put(("status", "檢查更新中…"))

        local = read_local_version()
        rel = fetch_latest_release()

        if local == rel.tag and CURRENT_DIR.exists():
            q.put(("status", "已是最新版本，啟動中…"))
            launch_current()
            q.put(("done",))
            return

        asset = pick_asset(rel)
        zip_path = CACHE_DIR / asset.name

        q.put(("status", "下載更新中…"))
        http_download_with_progress(asset.url, zip_path, lambda *_: None)

        q.put(("status", "解壓縮中…"))
        next_dir = APP_DIR / f"next_{rel.tag}"
        extract_zip(zip_path, next_dir)

        q.put(("status", "套用更新中…"))
        atomic_switch(next_dir)
        write_local_version(rel.tag)

        q.put(("status", "啟動 FH5Bot…"))
        launch_current()
        q.put(("done",))

    except Exception as e:
        q.put(("error", str(e)))

# ========================
# UI
# ========================
def run_ui():
    root = tk.Tk()
    root.title("FH5Bot Launcher")
    root.resizable(False, False)

    frm = ttk.Frame(root, padding=12)
    frm.pack()

    status_var = tk.StringVar(value="準備中…")
    ttk.Label(frm, textvariable=status_var, width=50).pack(pady=6)

    pb = ttk.Progressbar(frm, length=420, mode="indeterminate")
    pb.pack(pady=6)
    pb.start(10)

    q = Queue()
    threading.Thread(target=worker, args=(q,), daemon=True).start()

    def poll():
        try:
            while True:
                m = q.get_nowait()
                if m[0] == "status":
                    status_var.set(m[1])
                elif m[0] == "done":
                    status_var.set("完成，啟動中…")
                    root.after(1500, root.destroy)  # ✅ 關鍵修正
                elif m[0] == "error":
                    messagebox.showerror("Launcher Error", m[1])
        except Empty:
            pass
        root.after(100, poll)

    poll()
    root.mainloop()


if __name__ == "__main__":
    run_ui()
