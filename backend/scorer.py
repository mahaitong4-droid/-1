"""规则打分引擎：不调用任何 AI、不花一分钱，给每家店算「用工需求分」。

这是默认引擎，同时也是所有 AI 路径的兜底 —— AI 调用失败时回落到这里，
而不是给 0 分把整批店废掉。

词库在 data/labor_keywords.txt，用户可自行增删改权重，改完下次分析立即生效。
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from .poi import Merchant

log = logging.getLogger(__name__)

__all__ = ["RuleScorer", "ScoreBreakdown"]

# 一个基础分词都没命中时的中性基准（普通小餐馆）
DEFAULT_BASE = 45

# 各分组的默认权重（词条没写 `=数值` 时用）
_SECTION_DEFAULTS = {"B": DEFAULT_BASE, "P": 10, "M": -8, "N": 10}


@dataclass
class ScoreBreakdown:
    score: int
    reason: str


class RuleScorer:
    """基于关键词权重的用工需求打分器。"""

    def __init__(self, keywords_file: Path | str):
        self._path = Path(keywords_file)
        self._mtime: float | None = None
        self._groups: dict[str, list[tuple[str, int]]] = {}
        self._load()

    # ---------- 词库加载 ----------

    def _load(self) -> None:
        groups: dict[str, list[tuple[str, int]]] = {"B": [], "P": [], "M": [], "N": []}
        try:
            text = self._path.read_text(encoding="utf-8")
        except OSError as e:
            log.warning("用工词库 %s 读取失败，全部使用默认基准分: %s", self._path, e)
            self._groups = groups
            return

        current: str | None = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                tag = line[1:2].upper()
                current = tag if tag in groups else None
                continue
            if current is None:
                continue
            word, _, val = line.partition("=")
            word = word.strip()
            if not word:
                continue
            try:
                weight = int(val.strip()) if val.strip() else _SECTION_DEFAULTS[current]
            except ValueError:
                weight = _SECTION_DEFAULTS[current]
            groups[current].append((word, weight))

        # 长词优先，避免"烤肉自助"被"烤肉"先吞掉
        for k in groups:
            groups[k].sort(key=lambda kv: len(kv[0]), reverse=True)
        self._groups = groups
        try:
            self._mtime = self._path.stat().st_mtime
        except OSError:
            self._mtime = None
        log.info(
            "用工词库已加载: 基础%d 加分%d 减分%d 夜间%d",
            *(len(groups[k]) for k in ("B", "P", "M", "N")),
        )

    def reload_if_changed(self) -> None:
        """词库文件改动后自动重载，用户编辑完不用重启服务。"""
        try:
            mtime = self._path.stat().st_mtime
        except OSError:
            return
        if self._mtime is None or mtime > self._mtime:
            self._load()

    # ---------- 打分 ----------

    def _best_base(self, text: str) -> tuple[int, str]:
        """在一段文本里找基础分最高的命中词。"""
        best, word = -1, ""
        for w, weight in self._groups["B"]:
            if w in text and weight > best:
                best, word = weight, w
        return best, word

    def _best_delta(self, text: str, group: str) -> tuple[int, str]:
        """在一段文本里找该分组中影响最大（绝对值最大）的命中词。"""
        best, word = 0, ""
        for w, weight in self._groups[group]:
            if w in text and abs(weight) > abs(best):
                best, word = weight, w
        return best, word

    def score(self, m: Merchant) -> ScoreBreakdown:
        name = m.name or ""
        category = m.type_name or ""

        # 店名比数据源的粗类目更具体，优先采信。
        # 否则腾讯统一打的 "美食:中餐厅"(62) 会把"面馆"(45)、"早餐"(28) 全部抬高。
        base, base_word = self._best_base(name)
        if base < 0:
            base, base_word = self._best_base(category)
        if base < 0:
            base, base_word = DEFAULT_BASE, ""

        total = base
        notes = [f"{base_word or '普通餐饮'}({base})"]

        haystack = f"{name} {category}"
        for group, label in (("N", "夜"), ("P", "规模"), ("M", "小微")):
            delta, word = self._best_delta(haystack, group)
            if delta:
                total += delta
                notes.append(f"{label}·{word}{delta:+d}")

        total = max(0, min(100, total))
        return ScoreBreakdown(score=total, reason=" ".join(notes)[:60])

    def apply(self, merchants: list[Merchant], *, note: str = "") -> None:
        """就地把分数写回 Merchant。note 用于标注这是兜底估分。"""
        self.reload_if_changed()
        for m in merchants:
            b = self.score(m)
            m.labor_score = b.score
            m.labor_reason = f"{note}{b.reason}" if note else b.reason
