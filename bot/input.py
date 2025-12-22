import time
from collections import deque
from typing import Callable, Optional, Union

import pyautogui
from pynput.keyboard import Controller, Key

# 全域 Controller（pynput 用來送鍵）
_KB = Controller()

# 允許的 key alias（避免不同電腦/環境 key 名稱不一致）
_KEY_ALIASES = {
    "pgup": "pgup",
    "pageup": "pgup",
    "page_up": "pgup",

    "pgdn": "pgdn",
    "pgdown": "pgdn",
    "pagedown": "pgdn",
    "page_down": "pgdn",
}


def _normalize_key(key: str) -> str:
    k = (key or "").strip().lower()
    return _KEY_ALIASES.get(k, k)


def _pynput_key(k: str) -> Optional[Union[Key, str]]:
    """
    回傳 pynput 可用的 Key 或字元。只針對少數在遊戲中較不穩的鍵使用。
    """
    k = _normalize_key(k)
    if k == "pgup":
        return Key.page_up
    if k == "pgdn":
        return Key.page_down
    return None


class AbortBot(Exception):
    """致命中止：只用在滑鼠左上角緊急停止等情況"""
    pass


class RateLimiter:
    def __init__(self, max_per_min: int):
        self.max_per_min = max_per_min
        self.ts = deque()

    def allow(self) -> bool:
        now = time.time()
        while self.ts and now - self.ts[0] > 60:
            self.ts.popleft()
        if len(self.ts) >= self.max_per_min:
            return False
        self.ts.append(now)
        return True


def _corner_failsafe_check():
    x, y = pyautogui.position()
    if x <= 2 and y <= 2:
        raise AbortBot("緊急保護已觸發（滑鼠位於左上角）")


def _stop_requested(get_stop: Optional[Callable[[], bool]]) -> bool:
    try:
        return bool(get_stop and get_stop())
    except Exception:
        return False


def _send_press(key: str):
    """
    統一送出「按一下」。
    - pgup/pgdn：優先用 pynput（對某些環境更穩）
    - 其他：沿用 pyautogui
    """
    key_norm = _normalize_key(key)

    pk = _pynput_key(key_norm)
    if pk is not None:
        # pynput 送 PageUp/PageDown
        try:
            _KB.press(pk)
            _KB.release(pk)
            return
        except Exception:
            # fallback：如果 pynput 也失敗，再嘗試 pyautogui
            pass

    # pyautogui 送鍵（再做一次常見別名 fallback）
    for candidate in (key_norm,):
        try:
            pyautogui.press(candidate)
            return
        except Exception:
            pass

    # 最後 fallback：pageup/pagedown 這些名字在不同版本 pyautogui 有差異
    if key_norm == "pgup":
        for candidate in ("pageup", "page_up"):
            try:
                pyautogui.press(candidate)
                return
            except Exception:
                pass
    elif key_norm == "pgdn":
        for candidate in ("pagedown", "page_down"):
            try:
                pyautogui.press(candidate)
                return
            except Exception:
                pass

    # 真的都失敗就丟出例外，讓 log 看得到問題
    raise RuntimeError(f"Failed to press key: {key}")


def _send_keydown(key: str):
    """
    統一送出 keyDown。pgup/pgdn 也提供 pynput 版本。
    """
    key_norm = _normalize_key(key)

    pk = _pynput_key(key_norm)
    if pk is not None:
        try:
            _KB.press(pk)
            return
        except Exception:
            pass

    pyautogui.keyDown(key_norm)


def _send_keyup(key: str):
    """
    統一送出 keyUp。pgup/pgdn 也提供 pynput 版本。
    """
    key_norm = _normalize_key(key)

    pk = _pynput_key(key_norm)
    if pk is not None:
        try:
            _KB.release(pk)
            return
        except Exception:
            pass

    pyautogui.keyUp(key_norm)


def safe_press(
    key: str,
    repeat: int,
    interval: float,
    limiter: RateLimiter,
    get_stop: Optional[Callable[[], bool]] = None
) -> bool:
    key_norm = _normalize_key(key)

    for _ in range(repeat):
        _corner_failsafe_check()
        if _stop_requested(get_stop):
            return False

        if not limiter.allow():
            return False

        _send_press(key_norm)

        # interval 期間也可中斷
        if interval > 0:
            end = time.time() + interval
            while time.time() < end:
                _corner_failsafe_check()
                if _stop_requested(get_stop):
                    return False
                time.sleep(0.05)

    return True


def safe_hold(
    key: str,
    hold_sec: float,
    limiter: RateLimiter,
    get_stop: Optional[Callable[[], bool]] = None,
    on_down: Optional[Callable[[str], None]] = None,
    on_up: Optional[Callable[[str], None]] = None
) -> bool:
    key_norm = _normalize_key(key)

    _corner_failsafe_check()
    if _stop_requested(get_stop):
        return False

    if not limiter.allow():
        return False

    _send_keydown(key_norm)
    if on_down:
        try:
            on_down(key_norm)
        except Exception:
            pass

    completed = True
    try:
        end = time.time() + hold_sec
        while True:
            _corner_failsafe_check()
            if _stop_requested(get_stop):
                completed = False
                break
            if time.time() >= end:
                break
            time.sleep(0.05)
    finally:
        _send_keyup(key_norm)
        if on_up:
            try:
                on_up(key_norm)
            except Exception:
                pass

    return completed
