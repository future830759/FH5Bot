from dataclasses import dataclass
from typing import Optional, Tuple, List
import os, sys


def resource_path(rel_path: str) -> str:
    # PyInstaller onefile 會把檔案解到 sys._MEIPASS
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(base, rel_path)


def asset(filename: str) -> str:
    return resource_path(os.path.join("assets", filename))


Region = Optional[Tuple[int, int, int, int]]  # (left, top, width, height) 或 None=全螢幕


@dataclass
class RuleCfg:
    name: str
    img: str
    action: str              # "press" 或 "hold"
    key: str

    priority: int = 100      # 數字越小越優先
    cell: int = 4            # 九宮格（0~8）
    region: Region = None    # (left, top, width, height)

    # 動作參數
    repeat: int = 1
    interval: float = 0.06  # 重複按鍵間隔（秒）
    hold_sec: float = 0.0

    # 判斷 / 時間控制
    threshold: float = 0.88 # 圖片相似度門檻（0.0~1.0）
    cooldown: float = 1.0   # ✅ 新增：命中後冷卻多久才可再命中（秒）
    delay_sec: float = 0.0   # ✅ 新增：命中後等待多久才執行（秒）


@dataclass
class BotCfg:
    poll_sec: float = 0.15
    max_keys_per_min: int = 240
    failsafe: bool = True


CFG = BotCfg()

CFG.debug_region = False   # ✅ 開：命中時印 region 可複製
# CFG.debug_region = False  # ❌ 關：不印 region

RULES: List[RuleCfg] = [

    # ================= 主流程 =================

    RuleCfg(
        name="R1",
        img=asset("link.png"),
        action="press",
        key="esc",
        region=(270, 1326, 126, 44),
        cooldown=10.0,
        threshold=0.94,
        priority=5,
    ),

    RuleCfg(
        name="R2",
        img=asset("Creative_Center.png"),
        action="press",
        key="pgdn",
        repeat=6,
        interval=0.2,
        region=(1730, 246, 134, 47),
        threshold=0.9,
        cooldown=5.0,
        delay_sec=1.0,
    ),

    RuleCfg(
        name="R12_1",
        img=asset("shop.png"),
        action="press",
        key="pgup",
        region=(1856, 243, 151, 51),
        priority=4,
    ),

    RuleCfg(
        name="R3",
        img=asset("Game_community_self-made_events.png"),
        action="press",
        key="enter",
        region=(1327, 1091, 140, 38),
        cooldown=10.0,
    ),

    RuleCfg(
        name="R4",
        img=asset("Activity_blueprint.png"),
        action="press",
        key="enter",
        region=(1207, 995, 260, 127),
        cooldown=10.0,
    ),

    RuleCfg(
        name="R5",
        img=asset("Competition_Blueprint.png"),
        action="press",
        key="pgdn",
        repeat=6,
        interval=0.2,
        region=(105, 157, 174, 58),
        priority=10,
        threshold=0.9,
        cooldown=10.0,
        delay_sec=1.0,
    ),

    RuleCfg(
        name="R6",
        img=asset("target_map.png"),
        action="press",
        key="enter",
        region=(973, 366, 236, 76),
        priority=5,
    ),

    RuleCfg(
        name="R7",
        img=asset("Single.png"),
        action="press",
        key="enter",
        region=(1243, 717, 72, 64),
        priority=5,
        cooldown=0.5,
    ),

    RuleCfg(
        name="R8",
        img=asset("my_vehicle.png"),
        action="press",
        key="enter",
        region=(148, 160, 157, 57),
        priority=5,
        cooldown=3.0,
    ),

    RuleCfg(
        name="R9",
        img=asset("Start_event.png"),
        action="press",
        key="enter",
        region=(250, 221, 235, 49),
        priority=5,
    ),

    RuleCfg(
        name="R10",
        img=asset("start.png"),
        action="hold",
        key="space",
        region=(70, 96, 75, 38),
        priority=1,
        threshold=0.88,
        hold_sec=60.0,
        cooldown=65.0,
    ),

    # ================= 底部操作 =================

    RuleCfg(
        name="R11",
        img=asset("continue.png"),
        action="press",
        key="enter",
        region=(99, 1315, 151, 37),
        priority=4,
    ),

    RuleCfg(
        name="R12",
        img=asset("skip.png"),
        action="press",
        key="enter",
        region=(97, 1313, 154, 40),
        priority=4,
    ),

    RuleCfg(
        name="R13",
        img=asset("Get_rewards.png"),
        action="press",
        key="enter",
        region=(100, 1316, 196, 35),
        priority=4,
    ),
    
]
