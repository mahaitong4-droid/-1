"""高德地图 Web服务 API 客户端 - 只用到 POI 文本搜索。

文档: https://lbs.amap.com/api/webservice/guide/api/search
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, asdict
from typing import Iterable

import httpx

POI_URL = "https://restapi.amap.com/v5/place/text"

# 餐饮一级分类码（高德POI分类），覆盖中餐/快餐/小吃/烧烤等
# 我们排除 050300(咖啡厅) 之类，但保留所有餐馆类目；奶茶/卤味在分类器里再剔除
RESTAURANT_TYPES = "050000"  # 餐饮服务大类，下面会再细过滤


@dataclass
class Merchant:
    poi_id: str
    name: str
    address: str
    location: str  # "lng,lat"
    lng: float
    lat: float
    typecode: str
    type_name: str  # 例如 "餐饮服务;中餐厅;江浙菜"
    adcode: str
    adname: str  # 区县名
    business_area: str  # 商圈名（高德标注的）
    tel: str
    parent: str = ""  # 母POI ID（连锁子店通常有parent）

    def primary_type(self) -> str:
        """返回最末级分类名，例如 '江浙菜'。"""
        return self.type_name.split(";")[-1] if self.type_name else ""


class AmapError(RuntimeError):
    pass


class AmapClient:
    def __init__(self, api_key: str, *, timeout: float = 15.0):
        self._key = api_key
        self._client = httpx.AsyncClient(timeout=timeout)

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "AmapClient":
        return self

    async def __aexit__(self, *_exc) -> None:
        await self.aclose()

    async def search_restaurants(
        self,
        city: str,
        *,
        region: str | None = None,
        max_pages: int = 10,
        page_size: int = 25,
    ) -> list[Merchant]:
        """抓取指定城市/区域内的所有餐饮POI。

        Args:
            city: 城市名，例如 "长沙"
            region: 可选区县名（如 "雨花区"）；如果给了region，会用 city+region 拼接做更精准搜索
            max_pages: 最多翻多少页（高德每次最多100条，建议page_size=25翻多页）
            page_size: 每页返回数量，最大25（v5 API 限制）
        """
        results: list[Merchant] = []
        seen: set[str] = set()
        region_kw = f"{city}{region}" if region else city
        page = 1
        while page <= max_pages:
            try:
                data = await self._call_poi(
                    keywords=region_kw,
                    types=RESTAURANT_TYPES,
                    region=city,
                    page=page,
                    page_size=page_size,
                )
            except AmapError as e:
                # 高德POI文本搜索硬上限1000条，跑到边缘会返回ENGINE_RESPONSE_DATA_ERROR
                # 已经拿到一些结果就用已有的，没拿到就把错误向上抛
                if results:
                    import logging
                    logging.getLogger(__name__).warning(
                        "高德在第%d页报错(已拿到%d家)，停止翻页: %s", page, len(results), e
                    )
                    break
                raise
            pois = data.get("pois") or []
            if not pois:
                break
            for p in pois:
                m = self._parse_poi(p)
                if m and m.poi_id not in seen:
                    seen.add(m.poi_id)
                    results.append(m)
            if len(pois) < page_size:
                break
            page += 1
            await asyncio.sleep(0.2)  # 礼貌限速
        return results

    async def _call_poi(
        self,
        *,
        keywords: str,
        types: str,
        region: str,
        page: int,
        page_size: int,
    ) -> dict:
        params = {
            "key": self._key,
            "keywords": keywords,
            "types": types,
            "region": region,
            "city_limit": "true",
            "page_num": page,
            "page_size": page_size,
            "show_fields": "business,navi",
        }
        resp = await self._client.get(POI_URL, params=params)
        resp.raise_for_status()
        data = resp.json()
        if str(data.get("status")) != "1":
            raise AmapError(
                f"高德POI接口错误: status={data.get('status')} info={data.get('info')} "
                f"infocode={data.get('infocode')}"
            )
        return data

    @staticmethod
    def _parse_poi(p: dict) -> Merchant | None:
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
        )


def merchant_to_dict(m: Merchant) -> dict:
    return asdict(m)


def merchants_to_dicts(items: Iterable[Merchant]) -> list[dict]:
    return [asdict(m) for m in items]
