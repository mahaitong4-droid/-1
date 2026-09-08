"""POI 数据源层：腾讯位置服务 / 高德地图，产出统一的 Merchant。

为什么有这一层：
高德 Web 服务从 2025-05-20 起对个人开发者只给 10,000 次/月（跨服务共享），
腾讯位置服务个人开发者是 10,000 次/日，同样免费但宽松 30 倍。
所以默认走腾讯，高德保留可随时切回。

两个数据源都受"单次查询结果上限"限制（腾讯 400 条 = 20页x20，高德 1000 条），
所以统一采用**按菜系关键词分片查询再去重**的策略绕开上限，覆盖率反而比
单关键词翻页更高。
"""
from __future__ import annotations

import abc
import asyncio
import logging
from dataclasses import dataclass, field

import httpx

log = logging.getLogger(__name__)

__all__ = [
    "Merchant", "POIError", "POIQuotaError", "POIAuthError",
    "POIProvider", "AmapProvider", "TencentProvider", "build_poi_provider",
]

# 菜系分片关键词：每个词单独跑一轮分页查询，结果按 poi_id 去重合并。
# 想扩大覆盖面直接往这里加词即可。
CUISINE_SHARDS: tuple[str, ...] = (
    "中餐厅", "湘菜", "川菜", "家常菜", "火锅", "烧烤",
    "小龙虾", "海鲜", "大排档", "快餐", "面馆", "小吃",
)


@dataclass
class Merchant:
    poi_id: str
    name: str
    address: str
    location: str  # "lng,lat"
    lng: float
    lat: float
    typecode: str
    type_name: str      # 高德 "餐饮服务;中餐厅;江浙菜" / 腾讯 "美食:中餐厅:湘菜"
    adcode: str
    adname: str         # 区县名
    business_area: str  # 商圈名（只有高德会给，腾讯没有这个字段）
    tel: str
    parent: str = ""    # 母POI ID（连锁子店通常有parent，只有高德会给）
    source: str = ""    # "amap" / "tencent"
    # 用工需求分挂在这里（规则引擎或 AI 写入），避免用 setattr 挂野属性
    labor_score: int = 0
    labor_reason: str = ""
    matched_shard: str = field(default="", repr=False)

    def primary_type(self) -> str:
        """返回最末级分类名，例如 '江浙菜'。兼容高德的 ';' 和腾讯的 ':'。"""
        raw = (self.type_name or "").replace(":", ";")
        return raw.split(";")[-1].strip() if raw else ""


class POIError(RuntimeError):
    """POI 接口返回的可预期错误。"""


class POIQuotaError(POIError):
    """配额/限流类错误，文案要能直接给用户看。"""


class POIAuthError(POIError):
    """Key 无效 / 来源未授权。"""


class POIProvider(abc.ABC):
    """POI 数据源基类。子类只需实现单页查询，分片+翻页+去重在这里统一做。"""

    name: str = ""
    page_size: int = 20
    max_pages: int = 20      # 单个分片最多翻多少页
    throttle: float = 0.22   # 每次请求后的礼貌间隔（秒），腾讯个人 QPS 上限 5

    def __init__(self, api_key: str, *, timeout: float = 15.0):
        self._key = api_key
        self._client = httpx.AsyncClient(timeout=timeout)

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "POIProvider":
        return self

    async def __aexit__(self, *_exc) -> None:
        await self.aclose()

    @abc.abstractmethod
    async def _search_page(
        self, city: str, shard: str, page: int
    ) -> tuple[list[Merchant], bool]:
        """查一页。返回 (本页商户, 是否可能还有下一页)。"""

    async def search_restaurants(
        self,
        city: str,
        *,
        region: str | None = None,
        budget: int = 30,
        shards: tuple[str, ...] = CUISINE_SHARDS,
    ) -> list[Merchant]:
        """抓取指定城市/区域的餐饮 POI。

        Args:
            city: 城市名，如 "长沙"
            region: 可选区县名（如 "雨花区"）；按返回的区县名做过滤
            budget: 本次最多发起多少个接口请求（前端"抓取深度"映射过来）
            shards: 菜系分片关键词
        """
        collected: dict[str, Merchant] = {}
        exhausted: set[int] = set()
        calls = 0
        page = 1

        while calls < budget and len(exhausted) < len(shards) and page <= self.max_pages:
            for idx, shard in enumerate(shards):
                if calls >= budget:
                    break
                if idx in exhausted:
                    continue
                try:
                    items, has_more = await self._search_page(city, shard, page)
                except POIQuotaError:
                    # 配额打满：已经抓到东西就用手上的，一条没有才往上抛
                    if collected:
                        log.warning("配额超限，返回已抓到的 %d 家", len(collected))
                        return self._finalize(collected, region)
                    raise
                except POIAuthError:
                    raise  # key 有问题，重试也没用
                except POIError as e:
                    log.warning("分片『%s』第%d页失败，跳过该分片: %s", shard, page, e)
                    exhausted.add(idx)
                    continue
                calls += 1
                for m in items:
                    m.matched_shard = shard
                    collected.setdefault(m.poi_id, m)
                if not has_more:
                    exhausted.add(idx)
                await asyncio.sleep(self.throttle)
            page += 1

        log.info("%s 抓取完成: %d 次请求, 去重后 %d 家", self.name, calls, len(collected))
        return self._finalize(collected, region)

    @staticmethod
    def _finalize(collected: dict[str, Merchant], region: str | None) -> list[Merchant]:
        items = list(collected.values())
        if not region:
            return items
        # 区县过滤：两个数据源都只能按城市检索，区县靠返回的 adname 过滤
        key = region.strip().rstrip("区县市")
        if not key:
            return items
        filtered = [m for m in items if key in (m.adname or "")]
        log.info("区域『%s』过滤: %d → %d 家", region, len(items), len(filtered))
        return filtered


class TencentProvider(POIProvider):
    """腾讯位置服务 WebService - 地点搜索。

    文档: https://lbs.qq.com/service/webService/webServiceGuide/search/webServiceSearch
    个人开发者免费额度 10,000 次/日，QPS 5。
    """

    name = "tencent"
    page_size = 20   # 腾讯上限
    max_pages = 20   # 腾讯上限，单查询最多 400 条

    URL = "https://apis.map.qq.com/ws/place/v1/search"

    async def _search_page(self, city: str, shard: str, page: int):
        params = {
            "key": self._key,
            "keyword": shard,
            "boundary": f"region({city},0)",  # 0 = 不自动扩大范围
            "filter": "category=美食",
            "page_size": self.page_size,
            "page_index": page,
            "output": "json",
        }
        try:
            resp = await self._client.get(self.URL, params=params)
            resp.raise_for_status()
            data = resp.json()
        except httpx.HTTPError as e:
            raise POIError(f"腾讯接口请求失败: {e}") from e

        status = data.get("status")
        if status != 0:
            msg = data.get("message") or ""
            if status in (120, 121, 190):
                raise POIQuotaError(
                    f"腾讯位置服务配额已用完（个人开发者 10,000 次/日、每秒 5 次）：{msg}。"
                    f"明天再试，或在 .env 里把 POI_PROVIDER 切成 amap。"
                )
            if status in (110, 111, 112, 311):
                raise POIAuthError(
                    f"腾讯 Key 无效或来源未授权（status={status}）：{msg}。"
                    f"请检查 TENCENT_KEY，并确认控制台里该 key 已启用 WebServiceAPI。"
                )
            if status in (347, 348):
                return [], False  # 无结果，不是错误
            raise POIError(f"腾讯地点搜索错误: status={status} message={msg}")

        rows = data.get("data") or []
        merchants = [m for m in (self._parse(r) for r in rows) if m]
        # 腾讯 count 是本次检索总数；不足一页就说明到底了
        return merchants, len(rows) >= self.page_size

    def _parse(self, r: dict) -> Merchant | None:
        loc = r.get("location") or {}
        try:
            lng = float(loc["lng"])
            lat = float(loc["lat"])
        except (KeyError, TypeError, ValueError):
            return None
        ad = r.get("ad_info") or {}
        return Merchant(
            poi_id=str(r.get("id") or ""),
            name=r.get("title") or "",
            address=r.get("address") or "",
            location=f"{lng},{lat}",
            lng=lng,
            lat=lat,
            typecode=str(r.get("type") or ""),
            type_name=r.get("category") or "",
            adcode=str(ad.get("adcode") or ""),
            adname=ad.get("district") or "",
            business_area="",  # 腾讯不提供商圈字段，由 analyzer 的网格聚类兜底
            tel=r.get("tel") or "",
            source=self.name,
        )


class AmapProvider(POIProvider):
    """高德地图 Web 服务 - POI 文本搜索 v5。

    文档: https://lbs.amap.com/api/webservice/guide/api/search
    注意：2025-05-20 起个人开发者只有 10,000 次/月，且与 JS API 共享额度。
    """

    name = "amap"
    page_size = 25   # v5 单页上限
    max_pages = 40

    URL = "https://restapi.amap.com/v5/place/text"
    RESTAURANT_TYPES = "050000"  # 餐饮服务大类

    async def _search_page(self, city: str, shard: str, page: int):
        params = {
            "key": self._key,
            "keywords": shard,
            "types": self.RESTAURANT_TYPES,
            "region": city,
            "city_limit": "true",
            "page_num": page,
            "page_size": self.page_size,
            "show_fields": "business,navi",
        }
        try:
            resp = await self._client.get(self.URL, params=params)
            resp.raise_for_status()
            data = resp.json()
        except httpx.HTTPStatusError as e:
            # 高德配额打满时返回 HTTP 400 + QUOTA_EXCEEDED
            body = ""
            try:
                body = e.response.text[:200]
            except Exception:
                pass
            if e.response.status_code == 400 and "QUOTA" in body.upper():
                raise POIQuotaError(
                    "高德配额已用完（个人开发者 10,000 次/月，与 JS API 共享）。"
                    "建议在 .env 里把 POI_PROVIDER 切成 tencent（10,000 次/日）。"
                ) from e
            raise POIError(f"高德接口 HTTP 错误: {e}") from e
        except httpx.HTTPError as e:
            raise POIError(f"高德接口请求失败: {e}") from e

        if str(data.get("status")) != "1":
            info = str(data.get("info") or "")
            infocode = str(data.get("infocode") or "")
            if "QUOTA" in info.upper() or "LIMIT" in info.upper() or infocode.startswith("100"):
                raise POIQuotaError(
                    f"高德配额/限流（{info}）。个人开发者 10,000 次/月，"
                    f"建议在 .env 里把 POI_PROVIDER 切成 tencent（10,000 次/日）。"
                )
            if infocode in ("10001", "10009", "10008", "10012"):
                raise POIAuthError(f"高德 Key 无效或权限不足: {info} (infocode={infocode})")
            raise POIError(f"高德POI接口错误: info={info} infocode={infocode}")

        pois = data.get("pois") or []
        merchants = [m for m in (self._parse(p) for p in pois) if m]
        return merchants, len(pois) >= self.page_size

    def _parse(self, p: dict) -> Merchant | None:
        loc = (p.get("location") or "").strip()
        if not loc or "," not in loc:
            return None
        lng_s, lat_s = loc.split(",", 1)
        try:
            lng = float(lng_s)
            lat = float(lat_s)
        except ValueError:
            return None
        business = p.get("business") or {}
        return Merchant(
            poi_id=p.get("id") or "",
            name=p.get("name") or "",
            address=p.get("address") or "",
            location=loc,
            lng=lng,
            lat=lat,
            typecode=p.get("typecode") or "",
            type_name=p.get("type") or "",
            adcode=p.get("adcode") or "",
            adname=p.get("adname") or "",
            business_area=business.get("business_area") or "",
            tel=business.get("tel") or "",
            parent=p.get("parent") or "",
            source=self.name,
        )


def build_poi_provider(settings) -> POIProvider:
    """按配置选数据源。auto 时哪个 key 配了用哪个，都配了优先腾讯。"""
    choice = (settings.poi_provider or "auto").lower()
    if choice == "auto":
        choice = "tencent" if settings.tencent_key else ("amap" if settings.amap_backend_key else "")

    if choice == "tencent":
        if not settings.tencent_key:
            raise POIAuthError(
                "未配置 TENCENT_KEY。免费申请：https://lbs.qq.com/dev/console/key/manage"
                "（个人开发者 10,000 次/日）"
            )
        return TencentProvider(settings.tencent_key)

    if choice == "amap":
        if not settings.amap_backend_key:
            raise POIAuthError(
                "未配置 AMAP_BACKEND_KEY。免费申请：https://console.amap.com/dev/key/app"
                "（个人开发者 10,000 次/月）"
            )
        return AmapProvider(settings.amap_backend_key)

    raise POIAuthError(
        "还没有配置任何 POI 数据源 key。推荐腾讯位置服务（10,000 次/日，免费）："
        "https://lbs.qq.com/dev/console/key/manage —— 拿到 key 后填进 .env 的 TENCENT_KEY。"
    )
