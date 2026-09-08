"""规则筛选层：先用本地词库快速判断「连锁/奶茶/卤味」，剩下的留给AI兜底。"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .poi import Merchant


class Category(str, Enum):
    """商户分类（粗粒度）。"""
    TEA = "奶茶茶饮"      # 排除目标
    BRAISED = "卤味熟食"  # 排除目标
    CHAIN = "连锁餐饮"    # 排除目标
    INDEPENDENT = "独立餐饮"  # 目标候选
    UNKNOWN = "未确定"


@dataclass
class ClassifyResult:
    merchant: Merchant
    category: Category
    matched_brand: str = ""
    reason: str = ""


def _load_brand_groups(path: Path) -> dict[Category, list[str]]:
    """从词库文件加载分组品牌。"""
    groups: dict[Category, list[str]] = {
        Category.TEA: [],
        Category.BRAISED: [],
        Category.CHAIN: [],
    }
    current: Category | None = None
    section_map = {
        "T": Category.TEA,
        "L": Category.BRAISED,
        "C": Category.CHAIN,
        "K": Category.CHAIN,  # 连锁快餐归到CHAIN
    }
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            tag = line[1:2].upper() if len(line) >= 2 else ""
            current = section_map.get(tag)
            continue
        if current is None:
            continue
        groups[current].append(line)
    # 按长度降序，长串优先匹配（避免"绝味"误吞"绝胜"）
    for k in groups:
        groups[k].sort(key=len, reverse=True)
    return groups


class RuleClassifier:
    """基于词库的快速分类器。命中即返回，未命中标记为 UNKNOWN 留给AI。"""

    def __init__(self, brands_file: Path | str):
        self._path = Path(brands_file)
        self._mtime: float | None = None
        self._groups: dict[Category, list[str]] = {
            Category.TEA: [], Category.BRAISED: [], Category.CHAIN: [],
        }
        self._load()

    def _load(self) -> None:
        self._groups = _load_brand_groups(self._path)
        try:
            self._mtime = self._path.stat().st_mtime
        except OSError:
            self._mtime = None

    def reload_if_changed(self) -> None:
        """词库文件改动后自动重载 —— README 承诺"新加的品牌立即生效"，
        旧版本其实要重启服务才生效，这里补上。"""
        try:
            mtime = self._path.stat().st_mtime
        except OSError:
            return
        if self._mtime is None or mtime > self._mtime:
            self._load()

    def classify(self, m: Merchant) -> ClassifyResult:
        name = m.name or ""
        # 优先级：奶茶 > 卤味 > 连锁
        for cat in (Category.TEA, Category.BRAISED, Category.CHAIN):
            for brand in self._groups[cat]:
                if brand and brand in name:
                    return ClassifyResult(m, cat, brand, f"商户名包含品牌『{brand}』")

        # 用高德的细类名快速兜底
        primary = m.primary_type()
        if "茶" in primary or "咖啡" in primary or "饮品" in primary:
            return ClassifyResult(m, Category.TEA, "", f"高德分类『{primary}』为饮品")

        # 高德parent字段：有parent通常是连锁子店
        if m.parent:
            return ClassifyResult(m, Category.CHAIN, "", "高德标注为连锁子POI")

        return ClassifyResult(m, Category.UNKNOWN, "", "")


def is_target(cat: Category) -> bool:
    """是否是地推目标（独立非连锁餐饮）。"""
    return cat == Category.INDEPENDENT


def is_excluded(cat: Category) -> bool:
    """是否明确排除。"""
    return cat in (Category.TEA, Category.BRAISED, Category.CHAIN)
