# Launcher.py
# Debug mode:
#   set FH5BOT_DEBUG=1
# Optional workflow/UI pause (ms) - slows the ACTUAL worker steps:
#   set FH5BOT_UI_PAUSE_MS=350
# Build:
#   python -m PyInstaller -F -w --name FH5Bot --icon icon.ico Launcher.py

from __future__ import annotations

import json
import os
import re
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

import tkinter as tk
from tkinter import ttk, messagebox

# ========================
# 設定
# ========================
GITHUB_OWNER = "future830759"
GITHUB_REPO = "FH5Bot"

ASSET_NAME_RE_NEW = re.compile(r"^FH5Bot-(v?\d+\.\d+\.\d+)\.zip$", re.IGNORECASE)
ASSET_PREFIX_OLD = "app_"
ASSET_SUFFIX = ".zip"

MANIFEST_NAME = "manifest.json"
FORCE_NO_USER_SITE = True

# ✅ 統一 Debug 開關
DEBUG = os.environ.get("FH5BOT_DEBUG", "").strip().lower() in ("1", "true", "yes")

# ✅ 工作流程同步停留（毫秒）
DEFAULT_UI_PAUSE_MS = 450

# ========================
# UI 文案
# ========================
TXT_READY = "準備中…"
TXT_CHECKING = "檢查更新中…"
TXT_LOCAL_VER = "讀取本地版本…"
TXT_LATEST = "已是最新版本"
TXT_FOUND_NEW = "發現新版本 {tag}"
TXT_DOWNLOADING = "下載更新中…"
TXT_EXTRACTING = "解壓縮中…"
TXT_APPLYING = "套用更新中…"
TXT_UPDATED = "更新完成"
TXT_PREP_LAUNCH = "準備啟動 FH5Bot…"
TXT_LAUNCHING = "啟動 FH5Bot…"
TXT_DONE = "完成，啟動中…"

TXT_ERR_CHECK = "檢查更新失敗"
TXT_ERR_UPDATE = "更新失敗"
TXT_ERR_LAUNCH = "啟動失敗"
TXT_ERR_UNKNOWN = "發生未預期錯誤"

# ========================
# 路徑
# ========================
EXE_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent

APP_DIR = EXE_DIR / "app"
CURRENT_DIR = APP_DIR / "current"
CACHE_DIR = EXE_DIR / "cache"  # ✅ 只在需要下載時才建立；成功後會刪除
LOCAL_VERSION_FILE = EXE_DIR / "version.txt"
LOG_FILE = EXE_DIR / "launcher_debug.log"

# ✅ runtime 固定位置（不在 current 內）
RUNTIME_DIR = APP_DIR / "runtime"
RUNTIME_PY_DIR = RUNTIME_DIR / "python"
RUNTIME_PKGS_DIR = RUNTIME_DIR / "site-packages"
RUNTIME_PYTHONW = RUNTIME_PY_DIR / ("pythonw.exe" if os.name == "nt" else "python")

# ========================
# Debug console + logging
# ========================
def _enable_console_if_debug():
    if not DEBUG or os.name != "nt":
        return
    try:
        import ctypes  # type: ignore
        k32 = ctypes.windll.kernel32  # type: ignore
        if k32.GetConsoleWindow() == 0:
            k32.AllocConsole()
            sys.stdout = open("CONOUT$", "w", encoding="utf-8", errors="replace", buffering=1)
            sys.stderr = open("CONOUT$", "w", encoding="utf-8", errors="replace", buffering=1)
            sys.stdin = open("CONIN$", "r", encoding="utf-8", errors="replace")
    except Exception:
        pass


def log(msg: str):
    # ✅ 只有 DEBUG 才寫檔/印出
    if not DEBUG:
        return
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8", errors="replace") as f:
            f.write(line + "\n")
    except Exception:
        pass
    try:
        print(line, flush=True)
    except Exception:
        pass


_enable_console_if_debug()
log(f"Launcher start. DEBUG={DEBUG} EXE_DIR={EXE_DIR}")

# ========================
# cache 清理（你要的不保留）
# ========================
def cleanup_cache_dir(force: bool = False):
    """
    force=False: 只刪空資料夾（安全）
    force=True : 連內容一起刪（激進）
    """
    try:
        if not CACHE_DIR.exists():
            return

        if force:
            shutil.rmtree(CACHE_DIR, ignore_errors=True)
            return

        # 只刪空資料夾
        # （如果曾經下載失敗留下 .part/.zip，這裡不會動它，避免誤刪你要 debug 的現場）
        if any(CACHE_DIR.iterdir()):
            return
        CACHE_DIR.rmdir()
    except Exception:
        pass


# ========================
# HTTP / GitHub
# ========================
def _headers(json_api: bool = False) -> Dict[str, str]:
    h = {"User-Agent": "FH5Bot-Launcher"}
    if json_api:
        h["Accept"] = "application/vnd.github+json"
    return h


def http_get_json(url: str, timeout: int = 20) -> dict:
    log(f"HTTP GET JSON: {url}")
    req = Request(url, headers=_headers(True))
    with urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def http_download_with_progress(url: str, dest: Path, progress_cb) -> None:
    # ✅ 只有真的要下載才建立 cache
    dest.parent.mkdir(parents=True, exist_ok=True)

    log(f"Download: {url} -> {dest}")
    req = Request(url, headers=_headers())
    with urlopen(req) as resp:
        total = resp.headers.get("Content-Length")
        total = int(total) if total and total.isdigit() else None

        tmp = dest.with_suffix(".part")
        downloaded = 0
        progress_cb(downloaded, total)

        with tmp.open("wb") as f:
            while True:
                chunk = resp.read(1024 * 256)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                progress_cb(downloaded, total)

        tmp.replace(dest)
    log(f"Download done: {dest} size={dest.stat().st_size}")


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
    log(f"Latest release tag={tag}, assets={[a.name for a in assets]}")
    return LatestRelease(tag, assets)


def pick_asset(rel: LatestRelease) -> Asset:
    for a in rel.assets:
        if ASSET_NAME_RE_NEW.match(a.name):
            log(f"Pick asset(new): {a.name}")
            return a
    for a in rel.assets:
        if a.name.startswith(ASSET_PREFIX_OLD) and a.name.endswith(ASSET_SUFFIX):
            log(f"Pick asset(old): {a.name}")
            return a
    raise RuntimeError("找不到可用的更新檔（需要 FH5Bot-x.y.z.zip 或 app_*.zip）")


# ========================
# App ops（精簡：不備份 current、不建立 data）
# ========================
def ensure_dirs():
    # ✅ 只建立必要目錄：app、runtime
    for d in (APP_DIR, RUNTIME_DIR):
        d.mkdir(parents=True, exist_ok=True)
    log(f"Dirs ensured. APP_DIR={APP_DIR} RUNTIME_DIR={RUNTIME_DIR}")

    # ✅ 啟動時順手把空的 cache 刪掉（不影響任何流程）
    cleanup_cache_dir(force=False)


def read_local_version() -> str:
    v = LOCAL_VERSION_FILE.read_text(encoding="utf-8", errors="replace").strip() if LOCAL_VERSION_FILE.exists() else ""
    log(f"Local version='{v}'")
    return v


def write_local_version(ver: str):
    LOCAL_VERSION_FILE.write_text(ver.strip(), encoding="utf-8")
    log(f"Wrote local version='{ver}'")


def read_manifest() -> Tuple[str, list[str], dict]:
    mf = CURRENT_DIR / MANIFEST_NAME
    if not mf.exists():
        raise FileNotFoundError(f"找不到 {MANIFEST_NAME}：{mf}")
    cfg = json.loads(mf.read_text(encoding="utf-8", errors="replace"))
    entry = cfg.get("entry")
    args = cfg.get("args", [])
    if not entry:
        raise RuntimeError(f"{MANIFEST_NAME} 缺少 entry 欄位：{mf}")
    return str(entry), list(args), cfg


def resolve_entry(entry: str) -> Path:
    norm = entry.replace("\\", "/").lower()
    if norm.startswith("python/"):
        return RUNTIME_PYTHONW
    return (CURRENT_DIR / entry).resolve()


def ensure_embedded_python_pth():
    if os.name != "nt":
        return
    if not RUNTIME_PY_DIR.exists():
        return

    pth_files = list(RUNTIME_PY_DIR.glob("python*._pth"))
    if not pth_files:
        return

    pth = pth_files[0]
    try:
        raw_lines = pth.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return

    want_paths = [r"..\site-packages", r"..\..\current"]

    lines = []
    existing = set()
    import_site_present = False

    for ln in raw_lines:
        s = ln.strip()
        if not s:
            lines.append(ln)
            continue

        if s.lower() == "import site":
            import_site_present = True
            lines.append("import site")
            continue

        if s.lower().replace(" ", "") in ("#importsite", ";importsite"):
            import_site_present = True
            lines.append("import site")
            continue

        if not s.startswith("#") and not s.startswith(";"):
            existing.add(s.replace("/", "\\"))
        lines.append(ln)

    for wp in want_paths:
        wpn = wp.replace("/", "\\")
        if wpn not in existing:
            lines.insert(0, wpn)
            existing.add(wpn)

    if not import_site_present:
        lines.append("import site")

    new_text = "\n".join(lines).rstrip() + "\n"
    if new_text != "\n".join(raw_lines).rstrip() + "\n":
        try:
            pth.write_text(new_text, encoding="utf-8")
            log(f"Patched embedded python _pth: {pth}")
        except Exception:
            pass


def move_runtime_out_of_current_if_any():
    src_py = CURRENT_DIR / "python"
    src_pkgs = CURRENT_DIR / "site-packages"

    if src_py.exists() and not RUNTIME_PY_DIR.exists():
        log(f"Move runtime python: {src_py} -> {RUNTIME_PY_DIR}")
        if RUNTIME_PY_DIR.exists():
            shutil.rmtree(RUNTIME_PY_DIR, ignore_errors=True)
        shutil.move(str(src_py), str(RUNTIME_PY_DIR))

    if src_pkgs.exists() and not RUNTIME_PKGS_DIR.exists():
        log(f"Move runtime site-packages: {src_pkgs} -> {RUNTIME_PKGS_DIR}")
        if RUNTIME_PKGS_DIR.exists():
            shutil.rmtree(RUNTIME_PKGS_DIR, ignore_errors=True)
        shutil.move(str(src_pkgs), str(RUNTIME_PKGS_DIR))


def apply_update_overwrite_current(zip_path: Path):
    # 先清掉舊 current
    if CURRENT_DIR.exists():
        shutil.rmtree(CURRENT_DIR, ignore_errors=True)
    CURRENT_DIR.mkdir(parents=True, exist_ok=True)

    # 解壓到 current
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(CURRENT_DIR)

    # 刪 zip + part（理論上 part 已 rename，但保險）
    try:
        zip_path.unlink(missing_ok=True)
    except Exception:
        pass
    try:
        zip_path.with_suffix(".part").unlink(missing_ok=True)
    except Exception:
        pass

    # ✅ 成功後：cache 沒用就刪掉（只刪空資料夾，安全）
    cleanup_cache_dir(force=False)


def launch_current():
    entry, args, cfg = read_manifest()
    log(f"Manifest entry={entry} args={args}")

    move_runtime_out_of_current_if_any()
    ensure_embedded_python_pth()

    entry_path = resolve_entry(entry)
    log(f"Resolved entry path: {entry_path}")

    if not entry_path.exists():
        raise FileNotFoundError(f"要啟動的檔案不存在：{entry_path}")

    env = os.environ.copy()
    if FORCE_NO_USER_SITE:
        env["PYTHONNOUSERSITE"] = "1"

    paths = [str(RUNTIME_PKGS_DIR), str(CURRENT_DIR)]
    old = env.get("PYTHONPATH")
    if old:
        paths.append(old)
    env["PYTHONPATH"] = os.pathsep.join(paths)

    flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS if os.name == "nt" else 0
    cmd = [str(entry_path), *args]
    log(f"Launching: {cmd} cwd={CURRENT_DIR}")

    if DEBUG:
        run_log = EXE_DIR / "fh5bot_run.log"
        fh = open(run_log, "a", encoding="utf-8", errors="replace")
        stdout = fh
        stderr = fh
        log(f"Run log -> {run_log}")
    else:
        stdout = subprocess.DEVNULL
        stderr = subprocess.DEVNULL

    subprocess.Popen(
        cmd,
        cwd=str(CURRENT_DIR),
        env=env,
        creationflags=flags,
        close_fds=True,
        stdout=stdout,
        stderr=stderr,
    )


# ========================
# Worker（工作流程跟著停）
# ========================
def worker(q: Queue):
    try:
        ensure_dirs()

        pause_ms_raw = os.environ.get("FH5BOT_UI_PAUSE_MS", "").strip()
        try:
            pause_ms = int(pause_ms_raw) if pause_ms_raw else DEFAULT_UI_PAUSE_MS
        except Exception:
            pause_ms = DEFAULT_UI_PAUSE_MS
        pause_s = max(0, pause_ms) / 1000.0

        def step_status(text: str, do_pause: bool = True):
            q.put(("status", text))
            if do_pause and pause_s > 0:
                time.sleep(pause_s)

        q.put(("progress", 0, 1))

        step_status(TXT_CHECKING)
        local = read_local_version()

        step_status(TXT_CHECKING)
        rel = fetch_latest_release()

        if local == rel.tag and CURRENT_DIR.exists():
            step_status(TXT_LATEST)
            step_status(TXT_PREP_LAUNCH)
            step_status(TXT_LAUNCHING)
            launch_current()
            q.put(("done",))
            return

        step_status(TXT_FOUND_NEW.format(tag=rel.tag))

        asset = pick_asset(rel)
        zip_path = CACHE_DIR / asset.name

        q.put(("status", f"{TXT_DOWNLOADING} ({asset.name})"))

        def _on_progress(downloaded: int, total: Optional[int]):
            q.put(("download_progress", downloaded, total))

        http_download_with_progress(asset.url, zip_path, _on_progress)

        step_status(TXT_EXTRACTING)
        step_status(TXT_APPLYING)
        apply_update_overwrite_current(zip_path)
        write_local_version(rel.tag)

        step_status(TXT_UPDATED)
        step_status(TXT_PREP_LAUNCH)
        step_status(TXT_LAUNCHING)
        launch_current()
        q.put(("done",))

    except Exception as e:
        log(f"ERROR: {repr(e)}")
        q.put(("error", str(e)))


# ========================
# UI（dark + progressbar + detail）
# ========================
def _fmt_mb(n: int) -> str:
    return f"{n / (1024 * 1024):.1f} MB"


def apply_dark_theme(root: tk.Tk):
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass

    BG = "#111111"
    FG = "#3498db"
    MUTED = "#A0A0A0"
    BAR_BG = "#1A1A1A"

    root.configure(bg=BG)

    style.configure("Dark.TFrame", background=BG)
    style.configure("Dark.TLabel", background=BG, foreground=FG)
    style.configure("Hint.TLabel", background=BG, foreground=MUTED)

    style.configure(
        "Dark.Horizontal.TProgressbar",
        background=FG,
        troughcolor=BAR_BG,
        bordercolor=BAR_BG,
        lightcolor=BAR_BG,
        darkcolor=BAR_BG,
    )


def center_window(win: tk.Tk):
    win.update_idletasks()
    w = win.winfo_width()
    h = win.winfo_height()
    sw = win.winfo_screenwidth()
    sh = win.winfo_screenheight()
    x = (sw - w) // 2
    y = (sh - h) // 2
    win.geometry(f"{w}x{h}+{x}+{y}")


def run_ui():
    root = tk.Tk()
    root.title("FH5Bot (DEBUG)" if DEBUG else "FH5Bot")
    root.resizable(False, False)

    apply_dark_theme(root)

    frm = ttk.Frame(root, padding=12, style="Dark.TFrame")
    frm.pack()

    status_var = tk.StringVar(value=TXT_READY)
    pct_var = tk.StringVar(value="0%")
    detail_var = tk.StringVar(value="")

    ttk.Label(frm, textvariable=status_var, width=54, style="Dark.TLabel").pack(pady=(0, 6))
    ttk.Label(frm, textvariable=detail_var, width=54, style="Hint.TLabel").pack(pady=(0, 8))

    pb = ttk.Progressbar(frm, length=460, mode="determinate", style="Dark.Horizontal.TProgressbar", maximum=100)
    pb.pack(pady=(0, 6))
    ttk.Label(frm, textvariable=pct_var, width=54, style="Hint.TLabel").pack(pady=(0, 2))

    center_window(root)

    q = Queue()
    threading.Thread(target=worker, args=(q,), daemon=True).start()

    def set_download_progress(downloaded: int, total: Optional[int]):
        if total and total > 0:
            pb.configure(maximum=total)
            pb["value"] = min(downloaded, total)
            pct = int((downloaded / total) * 100)
            pct_var.set(f"{pct}%")
            detail_var.set(f"{_fmt_mb(downloaded)} / {_fmt_mb(total)}")
        else:
            pb.configure(maximum=100)
            pb["value"] = (downloaded // (1024 * 256)) % 100
            pct_var.set("下載中…")
            detail_var.set(_fmt_mb(downloaded))

    def poll():
        try:
            last_dl = None
            while True:
                m = q.get_nowait()
                kind = m[0]

                if kind == "status":
                    status_var.set(m[1])

                elif kind == "download_progress":
                    last_dl = m

                elif kind == "progress":
                    cur, mx = m[1], m[2]
                    pb.configure(maximum=max(mx, 1))
                    pb["value"] = min(cur, mx)
                    pct_var.set("100%" if cur >= mx else "0%")
                    detail_var.set("")

                elif kind == "done":
                    status_var.set(TXT_DONE)
                    root.after(1200, root.destroy)
                    return

                elif kind == "error":
                    raw = str(m[1])
                    title = TXT_ERR_UNKNOWN
                    low = raw.lower()
                    if "api.github.com" in low or "urlopen" in low or "timed out" in low:
                        title = TXT_ERR_CHECK
                    elif "找不到可用的更新檔" in raw or "zip" in low or "extract" in low:
                        title = TXT_ERR_UPDATE
                    elif "要啟動的檔案不存在" in raw or "manifest" in low:
                        title = TXT_ERR_LAUNCH

                    msg = raw
                    if DEBUG:
                        msg += f"\n\nDebug logs:\n{LOG_FILE}\n{EXE_DIR / 'fh5bot_run.log'}"
                    messagebox.showerror(title, msg)
                    root.after(200, root.destroy)
                    return

        except Empty:
            pass

        if last_dl is not None:
            set_download_progress(last_dl[1], last_dl[2])

        root.after(80, poll)

    poll()
    root.mainloop()


if __name__ == "__main__":
    run_ui()
