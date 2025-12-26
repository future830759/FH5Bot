import time
import pyautogui
from dataclasses import dataclass
from typing import List, Dict, Tuple, Set, Optional, Callable

from .input import AbortBot
from .config import CFG, RULES, RuleCfg
from .vision import screenshot_bgr, load_template, match_best, cell_to_region
from .input import RateLimiter, safe_press, safe_hold

Region = Tuple[int, int, int, int]


@dataclass
class RuleRuntime:
    cfg: RuleCfg
    tpl: object
    last_fire: float = 0.0


class Bot:
    def __init__(self, on_exec=None, stop_check: Optional[Callable[[], bool]] = None):
        self.on_exec = on_exec
        self.stop_check = stop_check

        self.running = False
        self.last_any_exec = time.time()

        self.held_keys: Set[str] = set()

        self.rules: List[RuleRuntime] = [
            RuleRuntime(cfg=r, tpl=load_template(r.img))
            for r in RULES
        ]
        self.rules.sort(key=lambda rr: (rr.cfg.priority, rr.cfg.name))

        self.limiter = RateLimiter(CFG.max_keys_per_min)

        # R1 被 R10 阻擋
        self.block_if: Dict[str, Set[str]] = {
            "R1": {"R10"},
        }

        # ✅ blocker 鎖存：只要 blocker 曾被看見，接下來一小段時間仍視為有效（避免 UI 閃動/更新毫秒差）
        self._block_latch_until: Dict[str, float] = {}
        self.block_latch_sec: float = 0.50     # 建議 0.35~0.80，先用 0.50
        self.block_recheck_sleep: float = 0.2 # 二次確認前等一下，讓 UI 有時間刷新（秒）

        self._by_name: Dict[str, RuleRuntime] = {rr.cfg.name: rr for rr in self.rules}

    def _is_stop_requested(self) -> bool:
        try:
            return bool(self.stop_check()) if self.stop_check else False
        except Exception:
            return False

    def release_all_keys(self):
        for k in list(self.held_keys):
            try:
                pyautogui.keyUp(k)
            except Exception:
                pass
        self.held_keys.clear()

        for k in ("space", "enter", "esc", "pgup", "pgdn", "w", "a", "s", "d"):
            try:
                pyautogui.keyUp(k)
            except Exception:
                pass

    def set_running(self, is_running: bool):
        # 暫停
        if self.running and not is_running:
            self.release_all_keys()

        # 重新啟動：清空 cooldown（你要的：resume 立刻能掃圖）
        if (not self.running) and is_running:
            now = time.time()
            for r in self.rules:
                r.last_fire = 0.0
            self.last_any_exec = now
            # latch 也清掉，避免 resume 後被前一輪殘影影響
            self._block_latch_until.clear()

        self.running = is_running

    def _rule_region(self, cfg: RuleCfg) -> Region:
        return cfg.region if cfg.region else cell_to_region(cfg.cell)

    def _sleep_with_failsafe(self, sec: float):
        end = time.time() + sec
        while time.time() < end:
            if self._is_stop_requested():
                raise AbortBot("已要求結束（F12）")
            if not self.running:
                return
            x, y = pyautogui.position()
            if x <= 2 and y <= 2:
                raise AbortBot("緊急保護已觸發（滑鼠位於左上角）")
            time.sleep(0.05)

    def _is_rule_visible(self, rr: RuleRuntime, frame) -> bool:
        score, _ = match_best(frame, rr.tpl)
        return score >= rr.cfg.threshold

    def _update_latch(self, blocker_name: str, visible: bool, now: float):
        if visible:
            until = now + self.block_latch_sec
            prev = self._block_latch_until.get(blocker_name, 0.0)
            if until > prev:
                self._block_latch_until[blocker_name] = until

    def _is_blocker_effective(self, blocker_name: str, visible_now: bool, now: float) -> bool:
        if visible_now:
            return True
        return now < self._block_latch_until.get(blocker_name, 0.0)

    def tick(self):
        now = time.time()
        debug_region = bool(getattr(CFG, "debug_region", False))

        # 1️⃣ active 只用來決定「誰能執行」
        active = [r for r in self.rules if now - r.last_fire >= r.cfg.cooldown]
        if not active:
            self._sleep_with_failsafe(CFG.poll_sec)
            return

        # 2️⃣ blocker 永遠要被截圖（不管 cooldown）
        needed_names: Set[str] = {r.cfg.name for r in active}
        for blockers in self.block_if.values():
            needed_names |= blockers

        frames: Dict[Region, object] = {}
        name_to_region: Dict[str, Region] = {}

        for name in needed_names:
            rr = self._by_name.get(name)
            if not rr:
                continue
            reg = self._rule_region(rr.cfg)
            name_to_region[name] = reg
            if reg not in frames:
                frames[reg] = screenshot_bgr(reg)

        # 3️⃣ 計算可見 blockers（無視 cooldown）+ 更新 latch
        visible_blockers: Set[str] = set()
        for blockers in self.block_if.values():
            for b in blockers:
                rr_b = self._by_name.get(b)
                if not rr_b:
                    continue
                reg_b = name_to_region.get(b) or self._rule_region(rr_b.cfg)
                frame_b = frames.get(reg_b)
                if frame_b is None:
                    frame_b = screenshot_bgr(reg_b)
                    frames[reg_b] = frame_b

                vis = self._is_rule_visible(rr_b, frame_b)
                if vis:
                    visible_blockers.add(b)
                self._update_latch(b, vis, now)

        # 4️⃣ 掃描 active
        for r in active:
            if self._is_stop_requested():
                raise AbortBot("已要求結束（F12）")
            if not self.running:
                return

            blockers = self.block_if.get(r.cfg.name)

            # ✅ 先用「本輪 visible + latch」擋一次
            if blockers:
                blocked = False
                for b in blockers:
                    if self._is_blocker_effective(b, (b in visible_blockers), now):
                        blocked = True
                        break
                if blocked:
                    continue

            reg = name_to_region.get(r.cfg.name) or self._rule_region(r.cfg)
            frame = frames[reg]
            score, loc = match_best(frame, r.tpl)
            if score < r.cfg.threshold:
                continue

            # ✅ 二次確認：只針對有 blockers 的 target（例如 R1）
            # 避免「R1 先亮幾毫秒 -> 立刻按 ESC」的插隊窗
            if blockers:
                if self.block_recheck_sleep > 0:
                    self._sleep_with_failsafe(self.block_recheck_sleep)
                    if not self.running or self._is_stop_requested():
                        return

                now2 = time.time()
                blocked2 = False
                for b in blockers:
                    rr_b = self._by_name.get(b)
                    if not rr_b:
                        continue
                    reg_b = self._rule_region(rr_b.cfg)
                    frame_b2 = screenshot_bgr(reg_b)  # 最新畫面
                    vis2 = self._is_rule_visible(rr_b, frame_b2)
                    self._update_latch(b, vis2, now2)
                    if self._is_blocker_effective(b, vis2, now2):
                        blocked2 = True
                        break
                if blocked2:
                    continue

            # ✅ A：命中就印 region + 命中座標（螢幕絕對座標）
            if debug_region:
                left, top, _, _ = reg
                abs_x = left + int(loc[0])
                abs_y = top + int(loc[1])
                print(
                    f"[DEBUG] {r.cfg.name}: score={score:.3f} "
                    f"region={reg} hit_abs=({abs_x}, {abs_y}) hit_local=({int(loc[0])}, {int(loc[1])})"
                )

            if self.on_exec:
                action_desc = (
                    f"hold {r.cfg.key} {r.cfg.hold_sec:.2f}s"
                    if r.cfg.action == "hold"
                    else f"press {r.cfg.key} x{r.cfg.repeat}"
                )
                self.on_exec(f"{r.cfg.name} | {score:.3f} | {action_desc}")

            if r.cfg.delay_sec > 0:
                self._sleep_with_failsafe(r.cfg.delay_sec)
                if not self.running:
                    return

            get_stop = lambda: (not self.running) or self._is_stop_requested()

            ok = (
                safe_hold(
                    r.cfg.key,
                    r.cfg.hold_sec,
                    self.limiter,
                    get_stop=get_stop,
                    on_down=lambda k: self.held_keys.add(k),
                    on_up=lambda k: self.held_keys.discard(k),
                )
                if r.cfg.action == "hold"
                else safe_press(
                    r.cfg.key,
                    r.cfg.repeat,
                    r.cfg.interval,
                    self.limiter,
                    get_stop=get_stop,
                )
            )

            if not ok:
                self.release_all_keys()
                return

            r.last_fire = time.time()
            self.last_any_exec = time.time()
            self._sleep_with_failsafe(max(CFG.poll_sec, 0.05))
            return

        self._sleep_with_failsafe(CFG.poll_sec)
