import cv2
import numpy as np
import pyautogui
import mss
import threading
from typing import Optional, Tuple


# =========================
# MSS：每個執行緒一個 instance（Windows 必須）
# =========================
_tls = threading.local()


def _get_sct() -> mss.mss:
    """
    每個 thread 一個 mss instance，避免 Windows 截圖 crash
    """
    if not hasattr(_tls, "sct"):
        _tls.sct = mss.mss()
    return _tls.sct


def screenshot_bgr(region: Optional[Tuple[int, int, int, int]]) -> np.ndarray:
    """
    使用 mss 截圖，回傳 OpenCV 可用的 BGR ndarray
    region: (left, top, width, height) 或 None = 全螢幕
    """
    sct = _get_sct()

    if region:
        left, top, width, height = region
        monitor = {
            "left": int(left),
            "top": int(top),
            "width": int(width),
            "height": int(height),
        }
    else:
        monitor = sct.monitors[1]  # 主螢幕

    img = sct.grab(monitor)

    # mss 回傳 BGRA，轉成 BGR
    frame = np.asarray(img, dtype=np.uint8)[:, :, :3]
    return frame


def load_template(path: str):
    """
    讀取模板圖片（支援中文路徑）
    """
    data = np.fromfile(path, dtype=np.uint8)
    if data.size == 0:
        raise FileNotFoundError(f"Template not found: {path}")
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f"Failed to decode template: {path}")
    return img


def match_score(frame_bgr: np.ndarray, tpl_bgr: np.ndarray) -> float:
    """
    OpenCV template matching，回傳最大相似度（保留舊 API）
    """
    res = cv2.matchTemplate(frame_bgr, tpl_bgr, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, _ = cv2.minMaxLoc(res)
    return float(max_val)


def match_best(frame_bgr: np.ndarray, tpl_bgr: np.ndarray) -> Tuple[float, Tuple[int, int]]:
    """
    ✅ 回傳 (max_score, (max_x, max_y))
    max_x/max_y 是「在 frame 內」的左上角座標
    """
    res = cv2.matchTemplate(frame_bgr, tpl_bgr, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(res)
    return float(max_val), (int(max_loc[0]), int(max_loc[1]))


def cell_to_region(cell: int) -> Tuple[int, int, int, int]:
    """
    依當前螢幕尺寸切成 3x3（cell 0~8）
    只用 pyautogui 取螢幕尺寸，不做截圖
    """
    w, h = pyautogui.size()
    cw, ch = w // 3, h // 3

    row = cell // 3
    col = cell % 3

    left = col * cw
    top = row * ch

    # 最右 / 最下格吃掉餘數避免漏邊
    width = (w - left) if col == 2 else cw
    height = (h - top) if row == 2 else ch

    return (left, top, width, height)
