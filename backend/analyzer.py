"""把分类后的商户按"商圈"聚合，输出地推热力图所需的统计数据。"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from .amap import Merchant
from .classifier import Category, ClassifyResult
from .deepseek import labor_score_of

# 用工需求分≥这个值算"有需求"
LABOR_DEMAND_THRESHOLD = 60


@dataclass
class MerchantSummary:
    """前端弹窗用的Top候选商户精简信息。"""
    name: str
    address: str
    lng: float
    lat: float
    labor_score: int
    reason: str
    poi_id: str

    @staticmethod
    def from_classify(cr: ClassifyResult) -> "MerchantSummary":
        m = cr.merchant
        return MerchantSummary(
            name=m.name,
            address=m.address,
            lng=m.lng,
            lat=m.lat,
            labor_score=labor_score_of(cr),
            reason=cr.reason,
            poi_id=m.poi_id,
        )


@dataclass
class BusinessAreaStats:
    """单个商圈的统计结果，前端用来画一个色块/Marker。"""
    name: str                  # 商圈名（无名归到"街道-XX"）
    adname: str                # 所属区
    center_lng: float
    center_lat: float
    total_qualified: int       # 独立餐饮总数
    high_demand: int           # 有用工需求的店数
    demand_ratio: float        # 占比 0~1
    avg_labor_score: float     # 平均用工分
    heat_level: str            # "high" / "mid" / "low"
    top_merchants: list[MerchantSummary]

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "adname": self.adname,
            "center": [self.center_lng, self.center_lat],
            "total_qualified": self.total_qualified,
            "high_demand": self.high_demand,
            "demand_ratio": round(self.demand_ratio, 3),
            "avg_labor_score": round(self.avg_labor_score, 1),
            "heat_level": self.heat_level,
            "top_merchants": [
                {
                    "name": tm.name,
                    "address": tm.address,
                    "lng": tm.lng,
                    "lat": tm.lat,
                    "labor_score": tm.labor_score,
                    "reason": tm.reason,
                    "poi_id": tm.poi_id,
                }
                for tm in self.top_merchants
            ],
        }


def _heat_level(ratio: float, total: int) -> str:
    """色块热度：商户数太少不算高，避免1家店100%误导。"""
    if total < 5:
        return "low"
    if ratio >= 0.5:
        return "high"
    if ratio >= 0.25:
        return "mid"
    return "low"


def aggregate_by_business_area(
    classify_results: list[ClassifyResult],
    *,
    top_n: int = 10,
) -> list[BusinessAreaStats]:
    """按business_area聚合。没标商圈的店按 adname+街道 兜底分组。"""
    # 只保留独立餐饮（已剔除奶茶/卤味/连锁）
    targets = [cr for cr in classify_results if cr.category == Category.INDEPENDENT]
    if not targets:
        return []

    groups: dict[tuple[str, str], list[ClassifyResult]] = defaultdict(list)
    for cr in targets:
        m = cr.merchant
        area = (m.business_area or "").strip()
        if not area:
            area = f"{m.adname or '未知区'}·散户"
        key = (area, m.adname or "")
        groups[key].append(cr)

    out: list[BusinessAreaStats] = []
    for (area, adname), items in groups.items():
        total = len(items)
        scores = [labor_score_of(cr) for cr in items]
        high_demand = sum(1 for s in scores if s >= LABOR_DEMAND_THRESHOLD)
        ratio = high_demand / total if total else 0.0
        avg = sum(scores) / total if total else 0.0

        # 中心点：所有店的经纬度平均
        center_lng = sum(cr.merchant.lng for cr in items) / total
        center_lat = sum(cr.merchant.lat for cr in items) / total

        # Top商户：按用工分倒序
        top_items = sorted(items, key=labor_score_of, reverse=True)[:top_n]
        top_summaries = [MerchantSummary.from_classify(cr) for cr in top_items]

        out.append(BusinessAreaStats(
            name=area,
            adname=adname,
            center_lng=center_lng,
            center_lat=center_lat,
            total_qualified=total,
            high_demand=high_demand,
            demand_ratio=ratio,
            avg_labor_score=avg,
            heat_level=_heat_level(ratio, total),
            top_merchants=top_summaries,
        ))

    # 默认按 high_demand 数量倒序（让"值得跑"的商圈排前面）
    out.sort(key=lambda s: (s.high_demand, s.demand_ratio), reverse=True)
    return out


@dataclass
class CityReport:
    city: str
    region: str | None
    total_pois: int          # 高德拉回的原始POI数
    excluded: dict[str, int] # 各类排除数量
    qualified: int           # 独立餐饮总数
    high_demand_total: int   # 全市/全区有用工需求总店数
    high_demand_ratio: float
    areas: list[BusinessAreaStats]

    def to_dict(self) -> dict:
        return {
            "city": self.city,
            "region": self.region,
            "total_pois": self.total_pois,
            "excluded": self.excluded,
            "qualified": self.qualified,
            "high_demand_total": self.high_demand_total,
            "high_demand_ratio": round(self.high_demand_ratio, 3),
            "areas": [a.to_dict() for a in self.areas],
        }


def build_city_report(
    city: str,
    region: str | None,
    classify_results: list[ClassifyResult],
    *,
    total_pois: int | None = None,
) -> CityReport:
    excluded = {
        Category.TEA.value: sum(1 for r in classify_results if r.category == Category.TEA),
        Category.BRAISED.value: sum(1 for r in classify_results if r.category == Category.BRAISED),
        Category.CHAIN.value: sum(1 for r in classify_results if r.category == Category.CHAIN),
    }
    qualified = sum(1 for r in classify_results if r.category == Category.INDEPENDENT)
    areas = aggregate_by_business_area(classify_results)
    hd_total = sum(a.high_demand for a in areas)
    return CityReport(
        city=city,
        region=region,
        total_pois=total_pois if total_pois is not None else len(classify_results),
        excluded=excluded,
        qualified=qualified,
        high_demand_total=hd_total,
        high_demand_ratio=(hd_total / qualified) if qualified else 0.0,
        areas=areas,
    )
