import time
import threading
from collections import deque

import pyautogui
import tkinter as tk
from pynput import keyboard as pynput_keyboard

from bot.state import Bot
from bot.input import AbortBot


def main():
    running = False
    stop_flag = False

    # ================= UI =================
    root = tk.Tk()
    root.title("FH5Bot")
    root.attributes("-topmost", True)
    root.resizable(False, False)
    root.overrideredirect(True)

    BG = "#111111"
    FG = "#E6E6E6"
    MUTED = "#9AA0A6"
    ACCENT = "#2ecc71"
    ALERT = "#e74c3c"

    root.configure(bg=BG)

    # ===== 固定寬度（維持以前）=====
    WIN_W = 400
    WIN_H = 240
    MARGIN = 50
    OFFSET_X = 20
    OFFSET_Y = 440

    # ============== Grid Layout（按鈕永遠底部） ==============
    root.grid_rowconfigure(0, weight=0)  # header
    root.grid_rowconfigure(1, weight=1)  # log（吃剩下）
    root.grid_rowconfigure(2, weight=0)  # buttons（固定底部）
    root.grid_columnconfigure(0, weight=1)

    header_frame = tk.Frame(root, bg=BG)
    header_frame.grid(row=0, column=0, sticky="ew")

    log_frame = tk.Frame(root, bg=BG)
    log_frame.grid(row=1, column=0, sticky="nsew", padx=10, pady=(6, 6))

    btn_frame = tk.Frame(root, bg=BG)
    btn_frame.grid(row=2, column=0, sticky="ew", padx=10, pady=(0, 8))

    # ================= Header =================
    status_var = tk.StringVar(value="已暫停")

    tk.Label(
        header_frame,
        text="狀態",
        font=("Segoe UI", 12),
        bg=BG,
        fg=MUTED
    ).pack(pady=(10, 0))

    status_lbl = tk.Label(
        header_frame,
        textvariable=status_var,
        font=("Segoe UI", 16, "bold"),
        bg=BG,
        fg=ALERT
    )
    status_lbl.pack(pady=(2, 6))

    title_frame = tk.Frame(header_frame, bg=BG)
    title_frame.pack(fill="x", padx=10)

    tk.Label(
        title_frame,
        text="最後執行規則",
        font=("Segoe UI", 10),
        bg=BG,
        fg=FG
    ).pack(side="left")

    r10_count = 0
    r10_var = tk.StringVar(value="R10 執行次數：0")

    tk.Label(
        title_frame,
        textvariable=r10_var,
        font=("Segoe UI", 10),
        bg=BG,
        fg=FG
    ).place(relx=0.5, rely=0.5, anchor="center")

    # ================= Log（無捲軸、寬度不變、不擠按鈕） =================
    MAX_LINES = 6
    last_lines = deque(maxlen=MAX_LINES)

    log_text = tk.Text(
        log_frame,
        height=MAX_LINES,
        wrap="word",
        font=("Consolas", 10),
        bg=BG,
        fg=FG,
        relief="flat",
        bd=0,
        highlightthickness=0,
        state="disabled"
    )
    log_text.pack(fill="both", expand=True)

    def refresh_log():
        log_text.configure(state="normal")
        log_text.delete("1.0", "end")
        if not last_lines:
            log_text.insert("end", "（尚無執行）")
        else:
            log_text.insert("end", "\n".join(last_lines))
        log_text.configure(state="disabled")

    def on_exec(msg: str):
        def _ui():
            nonlocal r10_count
            if msg.startswith("R10 |"):
                r10_count += 1
                r10_var.set(f"R10 執行次數：{r10_count}")
            last_lines.append(f"[執行] {msg}")
            refresh_log()

        try:
            root.after(0, _ui)
        except tk.TclError:
            pass

    bot = Bot(on_exec=on_exec, stop_check=lambda: stop_flag)

    # ================= Controls =================
    def update_status():
        status_var.set("執行中" if running else "已暫停")
        status_lbl.config(fg=ACCENT if running else ALERT)

    def toggle(_=None):
        nonlocal running
        if stop_flag:
            return
        running = not running
        bot.set_running(running)
        update_status()

    listener = None

    def quit_app(_=None):
        nonlocal stop_flag
        stop_flag = True
        try:
            bot.set_running(False)
        except Exception:
            pass
        try:
            if listener:
                listener.stop()
        except Exception:
            pass
        try:
            root.destroy()
        except Exception:
            pass
        raise SystemExit(0)

    # ================= Buttons =================
    btn_inner = tk.Frame(btn_frame, bg=BG)
    btn_inner.pack()

    tk.Button(
        btn_inner,
        text="開始 / 暫停（F8）",
        width=16,
        command=toggle,
        bg="#222222",
        fg=FG,
        activebackground="#333333",
        activeforeground=FG,
        relief="flat"
    ).grid(row=0, column=0, padx=4)

    tk.Button(
        btn_inner,
        text="結束（F12）",
        width=12,
        command=quit_app,
        bg="#222222",
        fg=FG,
        activebackground="#333333",
        activeforeground=FG,
        relief="flat"
    ).grid(row=0, column=1, padx=4)

    # ================= 透明度：滑鼠移入/移出 =================
    current_alpha = 0.80
    try:
        root.attributes("-alpha", current_alpha)
    except tk.TclError:
        pass

    def set_alpha(val: float):
        nonlocal current_alpha
        if current_alpha == val:
            return
        current_alpha = val
        try:
            root.attributes("-alpha", current_alpha)
        except tk.TclError:
            pass

    root.bind("<Enter>", lambda e: set_alpha(1.0))
    root.bind("<Leave>", lambda e: set_alpha(0.80))

    # ================= Hotkeys（pynput） =================
    pressed = {"f8": False, "f12": False}

    def on_press_key(key):
        try:
            if key == pynput_keyboard.Key.f8 and not pressed["f8"]:
                pressed["f8"] = True
                try:
                    root.after(0, toggle)
                except tk.TclError:
                    pass
            elif key == pynput_keyboard.Key.f12 and not pressed["f12"]:
                pressed["f12"] = True
                try:
                    root.after(0, quit_app)
                except tk.TclError:
                    pass
        except Exception:
            pass

    def on_release_key(key):
        try:
            if key == pynput_keyboard.Key.f8:
                pressed["f8"] = False
            elif key == pynput_keyboard.Key.f12:
                pressed["f12"] = False
        except Exception:
            pass

    listener = pynput_keyboard.Listener(on_press=on_press_key, on_release=on_release_key)
    listener.daemon = True
    listener.start()

    # ================= Window Size/Position（固定寬度 + 自動保底高度） =================
    root.update_idletasks()

    # 只允許自動「加高」，不允許自動加寬（維持以前寬度）
    req_h = max(WIN_H, root.winfo_reqheight())
    root.minsize(WIN_W, req_h)
    root.maxsize(WIN_W, req_h)

    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    x = sw - WIN_W - MARGIN - OFFSET_X
    y = sh - req_h - MARGIN - OFFSET_Y

    # clamp 回可視範圍，避免跑到螢幕外像「消失」
    x = max(0, min(x, max(0, sw - WIN_W)))
    y = max(0, min(y, max(0, sh - req_h)))

    root.geometry(f"{WIN_W}x{req_h}+{x}+{y}")

    # ================= Bot Loop =================
    def bot_loop():
        try:
            while not stop_flag:
                if running:
                    bot.tick()
                else:
                    time.sleep(0.1)
        except AbortBot as e:
            try:
                root.after(0, lambda: status_var.set(f"{e}"))
                root.after(300, quit_app)
            except tk.TclError:
                pass
        except pyautogui.FailSafeException:
            try:
                root.after(0, lambda: status_var.set("停止（失敗保護）"))
                root.after(300, quit_app)
            except tk.TclError:
                pass
        except SystemExit:
            pass

    threading.Thread(target=bot_loop, daemon=True).start()

    update_status()
    refresh_log()
    root.protocol("WM_DELETE_WINDOW", quit_app)
    root.mainloop()


if __name__ == "__main__":
    main()
