import time
import pyautogui
from dataclasses import dataclass
from typing import List, Dict, Tuple, Set, Optional, Callable

from .input import AbortBot
from .config import CFG, RULES, RuleCfg
from .vision import screenshot_bgr, load_template, match_best, cell_to_region
from .input import RateLimiter, safe_press, safe_hold

Region = Tuple[int, int, int, int]  # (left, top, width, height)


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
        # priority 小的先跑；name 做 tie-break 避免同 priority 順序飄
        self.rules.sort(key=lambda rr: (rr.cfg.priority, rr.cfg.name))

        self.limiter = RateLimiter(CFG.max_keys_per_min)

        # ✅ 阻擋規則：target 在執行前，如果 blocker 目前可見，則 target 直接跳過
        # 需求：R10 出現時，不要讓 R1（ESC）插隊
        self.block_if: Dict[str, Set[str]] = {
            "R1": {"R10"},
        }

        # name -> RuleRuntime
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
        if (self.running is True) and (is_running is False):
            self.release_all_keys()

        self.running = is_running
        if is_running:
            self.last_any_exec = time.time()

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

    def _is_rule_visible(self, rr: RuleRuntime, frames: Dict[Region, object]) -> bool:
        """只判斷畫面是否出現（不看 cooldown、不執行動作）"""
        reg = self._rule_region(rr.cfg)
        frame = frames[reg]
        score, _ = match_best(frame, rr.tpl)
        return score >= rr.cfg.threshold

    def tick(self):
        now = time.time()
        debug_region = bool(getattr(CFG, "debug_region", False))

        # ====== 1) cooldown 到期的規則才可執行 ======
        active: List[RuleRuntime] = [r for r in self.rules if now - r.last_fire >= r.cfg.cooldown]
        if not active:
            self._sleep_with_failsafe(CFG.poll_sec)
            return

        # ====== 2) 需要截圖的規則：active + 所有 blockers ======
        needed_names: Set[str] = {r.cfg.name for r in active}
        for target, blockers in self.block_if.items():
            for b in blockers:
                needed_names.add(b)

        frames: Dict[Region, object] = {}
        for name in needed_names:
            rr = self._by_name.get(name)
            if not rr:
                continue
            reg = self._rule_region(rr.cfg)
            if reg not in frames:
                frames[reg] = screenshot_bgr(reg)

        # ====== 3) 先算出目前「可見的 blockers」 ======
        visible_blockers: Set[str] = set()
        for target, blockers in self.block_if.items():
            for b in blockers:
                rr_b = self._by_name.get(b)
                if not rr_b:
                    continue
                if self._is_rule_visible(rr_b, frames):
                    visible_blockers.add(b)

        # ====== 4) 依 priority 順序掃 active ======
        for r in active:
            if self._is_stop_requested():
                raise AbortBot("已要求結束（F12）")
            if not self.running:
                return

            # ✅ 阻擋：例如 R10 可見時，R1 直接跳過
            blockers = self.block_if.get(r.cfg.name)
            if blockers and (visible_blockers & blockers):
                # 被阻擋就不比對、不執行，讓下一條有機會
                self._sleep_with_failsafe(max(0.01, CFG.poll_sec))
                continue

            reg = self._rule_region(r.cfg)
            frame = frames[reg]

            score, _ = match_best(frame, r.tpl)
            if score < r.cfg.threshold:
                continue

            if self.on_exec:
                action_desc = (
                    f"hold {r.cfg.key} {r.cfg.hold_sec:.2f}s"
                    if r.cfg.action == "hold"
                    else f"press {r.cfg.key} x{r.cfg.repeat}"
                )
                self.on_exec(f"{r.cfg.name} | {score:.3f} | {action_desc}")

            if debug_region:
                try:
                    print(f"[DEBUG] {r.cfg.name}: region={reg} score={score:.3f}")
                except Exception:
                    pass

            # delay_sec：命中後延遲（可被 F8 / F12 / failsafe 中斷）
            if r.cfg.delay_sec > 0:
                self._sleep_with_failsafe(r.cfg.delay_sec)
                if not self.running or self._is_stop_requested():
                    return

            get_stop = lambda: (not self.running) or self._is_stop_requested()

            ok = True
            if r.cfg.action == "hold":
                ok = safe_hold(
                    r.cfg.key,
                    r.cfg.hold_sec,
                    self.limiter,
                    get_stop=get_stop,
                    on_down=lambda k: self.held_keys.add(k),
                    on_up=lambda k: self.held_keys.discard(k),
                )
            else:
                ok = safe_press(
                    r.cfg.key,
                    r.cfg.repeat,
                    r.cfg.interval,
                    self.limiter,
                    get_stop=get_stop
                )

            if not ok:
                self.release_all_keys()
                if self._is_stop_requested():
                    raise AbortBot("已要求結束（F12）")
                return

            r.last_fire = time.time()
            self.last_any_exec = time.time()
            self._sleep_with_failsafe(max(CFG.poll_sec, 0.05))
            return

        self._sleep_with_failsafe(CFG.poll_sec)
