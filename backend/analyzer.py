"""把分类后的商户按"商圈"聚合，输出地推热力图所需的统计数据。

分组策略（这次改动的重点）：
1. 数据源给了商圈标注（只有高德有 business_area）→ 直接用
2. 没有商圈标注 → **按 ~800m 网格做空间聚类**，组名取该片区地址里出现
   最多的路名（如"韶山南路一带"）

为什么要加第 2 条：旧版本没商圈标注的店会全被塞进 "XX区·散户" 一个大桶，
中心点被平均到整个区的几何中心 —— 地图上画出来的圈子是错的。而腾讯 POI
根本不提供商圈字段，不做空间聚类就完全没法用。
"""
from __future__ import annotations

import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass

from .classifier import Category, ClassifyResult

# 默认用工需求阈值：分数 ≥ 这个值算"有需求"。可被 .env 的 LABOR_THRESHOLD 覆盖。
LABOR_DEMAND_THRESHOLD = 60
# 默认空间聚类网格边长（米）。可被 .env 的 GRID_SIZE_M 覆盖。
DEFAULT_GRID_SIZE_M = 800
# 单个片区最大半径（按网格数算）。800m 网格 x 2.5 = 2km，一个片区最大约走得到的范围。
MAX_CLUSTER_RADIUS_CELLS = 2.5

# 从地址里抠路名。先砍掉"省市区县"前缀，再取第一个 XX路/街/大道/巷。
_ADMIN_SPLIT = re.compile(r"[省市区县]")
_ROAD = re.compile(r"[一-龥]{1,8}?(?:大道|大街|路|街|巷)")


def _road_of(address: str) -> str:
    if not address:
        return ""
    tail = _ADMIN_SPLIT.split(address)[-1]
    m = _ROAD.search(tail)
    return m.group(0) if m else ""


def _grid_key(lng: float, lat: float, size_m: int, ref_lat: float) -> tuple[int, int]:
    """把经纬度落到 size_m 见方的网格里。

    经度方向 1 度的实际距离随纬度收缩，用整批数据的平均纬度做统一换算，
    这样网格是均匀的，相邻格子的距离可以直接按格子数算。
    """
    lat_step = size_m / 110_540.0
    lng_step = size_m / max(1.0, 111_320.0 * math.cos(math.radians(ref_lat)))
    return (int(math.floor(lat / lat_step)), int(math.floor(lng / lng_step)))


_NEIGHBORS8 = [(dy, dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if (dy, dx) != (0, 0)]


def _grow_clusters(
    cells: dict[tuple[int, int], list],
    *,
    max_radius_cells: float,
) -> dict[tuple[int, int], int]:
    """把相邻的占用网格合并成片区，返回 网格 → 片区编号。

    为什么不能只做硬分箱：马路对面相距 100 米的两家店，可能正好落在网格
    边界两侧，被拆成两个"商圈"。所以这里从最密的格子起做 8 邻域区域生长，
    把连片的格子并起来。

    同时用 max_radius_cells 限制单个片区的半径，避免市中心连片的餐饮
    被一路串成一个巨大的团（chaining），失去"分商圈"的意义。
    """
    # 从商户最多的格子开始生长，保证密集区先成团
    order = sorted(cells, key=lambda k: (-len(cells[k]), k))
    comp: dict[tuple[int, int], int] = {}
    cid = 0
    for seed in order:
        if seed in comp:
            continue
        cid += 1
        comp[seed] = cid
        queue = [seed]
        while queue:
            cy, cx = queue.pop()
            for dy, dx in _NEIGHBORS8:
                nb = (cy + dy, cx + dx)
                if nb in comp or nb not in cells:
                    continue
                # 网格均匀，格子间距离 = 边长 x 格子数差
                if math.hypot(nb[0] - seed[0], nb[1] - seed[1]) > max_radius_cells:
                    continue
                comp[nb] = cid
                queue.append(nb)
    return comp


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
            labor_score=m.labor_score,
            reason=m.labor_reason or cr.reason,
            poi_id=m.poi_id,
        )


@dataclass
class BusinessAreaStats:
    """单个商圈的统计结果，前端用来画一个色块/Marker。"""
    name: str                  # 商圈名或"XX路一带"
    adname: str                # 所属区
    center_lng: float
    center_lat: float
    total_qualified: int       # 独立餐饮总数
    high_demand: int           # 有用工需求的店数
    demand_ratio: float        # 占比 0~1
    avg_labor_score: float     # 平均用工分
    heat_level: str            # "high" / "mid" / "low"
    grouping: str              # "商圈标注" / "空间聚类"
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
            "grouping": self.grouping,
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
    if total < 3:
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
    threshold: int = LABOR_DEMAND_THRESHOLD,
    grid_size_m: int = DEFAULT_GRID_SIZE_M,
) -> list[BusinessAreaStats]:
    """按商圈聚合；没有商圈标注的走空间聚类。"""
    targets = [cr for cr in classify_results if cr.category == Category.INDEPENDENT]
    if not targets:
        return []

    groups: dict[tuple, list[ClassifyResult]] = defaultdict(list)
    unlabeled: list[ClassifyResult] = []
    for cr in targets:
        area = (cr.merchant.business_area or "").strip()
        if area:
            groups[("area", area, cr.merchant.adname or "")].append(cr)
        else:
            unlabeled.append(cr)

    # 没有商圈标注的（腾讯全部、高德一部分）走空间聚类
    if unlabeled:
        ref_lat = sum(cr.merchant.lat for cr in unlabeled) / len(unlabeled)
        cells: dict[tuple[int, int], list[ClassifyResult]] = defaultdict(list)
        for cr in unlabeled:
            cells[_grid_key(cr.merchant.lng, cr.merchant.lat, grid_size_m, ref_lat)].append(cr)
        comp = _grow_clusters(cells, max_radius_cells=MAX_CLUSTER_RADIUS_CELLS)
        for cell, items in cells.items():
            # 片区归属的区名取该片区里出现最多的，跨区的边界片区不会乱标
            groups[("grid", comp[cell])].extend(items)

    out: list[BusinessAreaStats] = []
    unnamed_seq: Counter[str] = Counter()

    for key, items in groups.items():
        if key[0] == "area":
            adname = key[2]
        else:
            adname = Counter(
                cr.merchant.adname for cr in items if cr.merchant.adname
            ).most_common(1)
            adname = adname[0][0] if adname else ""
        total = len(items)
        scores = [cr.merchant.labor_score for cr in items]
        high_demand = sum(1 for s in scores if s >= threshold)
        ratio = high_demand / total
        avg = sum(scores) / total

        center_lng = sum(cr.merchant.lng for cr in items) / total
        center_lat = sum(cr.merchant.lat for cr in items) / total

        if key[0] == "area":
            name, grouping = key[1], "商圈标注"
        else:
            grouping = "空间聚类"
            roads = Counter(
                r for r in (_road_of(cr.merchant.address) for cr in items) if r
            )
            if roads:
                name = f"{roads.most_common(1)[0][0]}一带"
            else:
                unnamed_seq[adname] += 1
                name = f"{adname or '未知区'}·片区{unnamed_seq[adname]}"

        top_items = sorted(items, key=lambda cr: cr.merchant.labor_score, reverse=True)[:top_n]

        out.append(BusinessAreaStats(
            name=name,
            adname=adname,
            center_lng=center_lng,
            center_lat=center_lat,
            total_qualified=total,
            high_demand=high_demand,
            demand_ratio=ratio,
            avg_labor_score=avg,
            heat_level=_heat_level(ratio, total),
            grouping=grouping,
            top_merchants=[MerchantSummary.from_classify(cr) for cr in top_items],
        ))

    # 同名片区合并显示时加序号，避免地图上出现两个"韶山南路一带"分不清
    name_counts = Counter(a.name for a in out)
    seen: Counter[str] = Counter()
    for a in out:
        if name_counts[a.name] > 1:
            seen[a.name] += 1
            a.name = f"{a.name}({seen[a.name]})"

    # 按 high_demand 数量倒序（让"值得跑"的商圈排前面）
    out.sort(key=lambda s: (s.high_demand, s.demand_ratio), reverse=True)
    return out


@dataclass
class CityReport:
    city: str
    region: str | None
    total_pois: int          # 数据源拉回的原始POI数
    excluded: dict[str, int] # 各类排除数量
    qualified: int           # 独立餐饮总数
    high_demand_total: int   # 全市/全区有用工需求总店数
    high_demand_ratio: float
    areas: list[BusinessAreaStats]
    engine: str = ""         # 本次用的数据源+打分引擎，前端显示用
    threshold: int = LABOR_DEMAND_THRESHOLD

    def to_dict(self) -> dict:
        return {
            "city": self.city,
            "region": self.region,
            "total_pois": self.total_pois,
            "excluded": self.excluded,
            "qualified": self.qualified,
            "high_demand_total": self.high_demand_total,
            "high_demand_ratio": round(self.high_demand_ratio, 3),
            "engine": self.engine,
            "threshold": self.threshold,
            "areas": [a.to_dict() for a in self.areas],
        }


def build_city_report(
    city: str,
    region: str | None,
    classify_results: list[ClassifyResult],
    *,
    total_pois: int | None = None,
    threshold: int = LABOR_DEMAND_THRESHOLD,
    grid_size_m: int = DEFAULT_GRID_SIZE_M,
    engine: str = "",
) -> CityReport:
    excluded = {
        Category.TEA.value: sum(1 for r in classify_results if r.category == Category.TEA),
        Category.BRAISED.value: sum(1 for r in classify_results if r.category == Category.BRAISED),
        Category.CHAIN.value: sum(1 for r in classify_results if r.category == Category.CHAIN),
    }
    qualified = sum(1 for r in classify_results if r.category == Category.INDEPENDENT)
    areas = aggregate_by_business_area(
        classify_results, threshold=threshold, grid_size_m=grid_size_m
    )
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
        engine=engine,
        threshold=threshold,
    )
