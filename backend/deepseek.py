"""调用 DeepSeek 对商户做二次分类 + 用工需求评分。

只把规则层判不准的（UNKNOWN）送进AI，省钱。
批量调用：一次 prompt 处理 20 家店，要求模型返回严格 JSON。
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Iterable

from openai import AsyncOpenAI

from .amap import Merchant
from .classifier import Category, ClassifyResult

log = logging.getLogger(__name__)

SYSTEM_PROMPT = """你是一名熟悉中国本地餐饮业的地推顾问。给你一批餐饮商户的基础信息，你需要为每家店输出严格的JSON结果。

任务：
1. 分类（category），只能是以下之一：
   - "奶茶茶饮": 奶茶店/茶饮店/咖啡馆/果汁店/冰品店
   - "卤味熟食": 卤味/熟食/鸭脖/烧腊/凉菜外带店
   - "连锁餐饮": 全国/区域连锁品牌门店（如华莱士、老乡鸡、海底捞、绝味鸭脖等）
   - "独立餐饮": 独立经营的中餐厅/小炒店/火锅店/烧烤店/小吃快餐店/夜宵摊等（非连锁、非奶茶、非卤味）
2. 用工需求强度（labor_demand_score，整数0-100）：
   - 评估该店"是否可能需要日结/短期临时工"
   - 参考维度：店铺规模（座位数/面积）、出餐节奏（火锅/烧烤/夜宵节奏快用工大）、营业时长（24小时/夜宵店用工大）、菜系特性（中餐小炒>面馆>简餐）
   - 90+：高强度刚需（大型火锅/烧烤/夜宵/连锁正餐）
   - 70-89：明显需求（中型中餐/串店/小龙虾店等）
   - 40-69：偶尔需求（小型快餐/面馆/简餐）
   - 0-39：基本无需求（极小店、夫妻档、自助/外卖为主）
3. 简短理由（reason，30字以内）

输出格式严格如下，每家店一个JSON对象，按输入顺序放进一个JSON数组：
[
  {"index": 0, "category": "独立餐饮", "labor_demand_score": 78, "reason": "中型湘菜馆，午晚高峰人手紧"},
  ...
]
只输出JSON数组本体，不要任何解释文字、markdown标记或代码块。"""


class DeepSeekClassifier:
    def __init__(self, api_key: str, *, model: str = "deepseek-chat", base_url: str = "https://api.deepseek.com"):
        self._client = AsyncOpenAI(api_key=api_key, base_url=base_url)
        self._model = model

    async def classify_batch(
        self,
        merchants: list[Merchant],
        *,
        batch_size: int = 20,
        concurrency: int = 3,
    ) -> list[dict]:
        """对未确定的商户批量调用AI判断。返回与 merchants 等长的字典列表。

        每个字典包含: {category, labor_demand_score, reason}
        """
        if not merchants:
            return []

        batches: list[list[Merchant]] = [
            merchants[i:i + batch_size] for i in range(0, len(merchants), batch_size)
        ]
        results: list[list[dict]] = [[] for _ in batches]
        sem = asyncio.Semaphore(concurrency)

        async def _run(idx: int, batch: list[Merchant]) -> None:
            async with sem:
                try:
                    results[idx] = await self._call_once(batch)
                except Exception as e:
                    log.warning("AI batch %d 失败: %s", idx, e)
                    results[idx] = [
                        {"category": Category.UNKNOWN.value, "labor_demand_score": 0,
                         "reason": "AI调用失败"} for _ in batch
                    ]

        await asyncio.gather(*[_run(i, b) for i, b in enumerate(batches)])
        flat: list[dict] = []
        for sub in results:
            flat.extend(sub)
        return flat

    async def _call_once(self, batch: list[Merchant]) -> list[dict]:
        user_payload = [
            {
                "index": i,
                "name": m.name,
                "type": m.type_name,
                "address": m.address,
                "adname": m.adname,
                "business_area": m.business_area,
            }
            for i, m in enumerate(batch)
        ]
        resp = await self._client.chat.completions.create(
            model=self._model,
            temperature=0.0,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": "请处理以下商户列表，并按要求输出。返回JSON对象，键名为items，值为数组：\n" + json.dumps(user_payload, ensure_ascii=False)},
            ],
        )
        text = resp.choices[0].message.content or ""
        data = self._parse_response(text, len(batch))
        return data

    @staticmethod
    def _parse_response(text: str, expected_len: int) -> list[dict]:
        text = text.strip()
        # 兼容模型偶尔加 ```json ... ``` 包裹
        if text.startswith("```"):
            text = text.strip("`")
            if text.lower().startswith("json"):
                text = text[4:].lstrip()
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            log.warning("AI返回非JSON: %s", text[:200])
            return [{"category": Category.UNKNOWN.value, "labor_demand_score": 0, "reason": "解析失败"}
                    for _ in range(expected_len)]
        items = obj.get("items") if isinstance(obj, dict) else obj
        if not isinstance(items, list):
            return [{"category": Category.UNKNOWN.value, "labor_demand_score": 0, "reason": "格式错误"}
                    for _ in range(expected_len)]
        # 按index排序兜底
        normalized: list[dict] = [
            {"category": Category.UNKNOWN.value, "labor_demand_score": 0, "reason": ""}
            for _ in range(expected_len)
        ]
        for it in items:
            if not isinstance(it, dict):
                continue
            idx = it.get("index")
            if not isinstance(idx, int) or idx < 0 or idx >= expected_len:
                continue
            cat = it.get("category") or Category.UNKNOWN.value
            score = it.get("labor_demand_score", 0)
            try:
                score = max(0, min(100, int(score)))
            except (TypeError, ValueError):
                score = 0
            normalized[idx] = {
                "category": cat,
                "labor_demand_score": score,
                "reason": (it.get("reason") or "")[:60],
            }
        return normalized


def merge_classification(
    rule_results: list[ClassifyResult],
    ai_results: list[dict],
) -> list[ClassifyResult]:
    """把AI对UNKNOWN商户的判断合并回ClassifyResult列表。

    rule_results: 规则层全量结果（含UNKNOWN）
    ai_results: 仅针对UNKNOWN项的AI结果，顺序与 rule_results 中UNKNOWN的顺序一致
    """
    ai_iter = iter(ai_results)
    merged: list[ClassifyResult] = []
    for rr in rule_results:
        if rr.category != Category.UNKNOWN:
            merged.append(rr)
            continue
        ai = next(ai_iter, None) or {}
        cat_str = ai.get("category", Category.UNKNOWN.value)
        try:
            cat = Category(cat_str)
        except ValueError:
            cat = Category.UNKNOWN
        merged.append(ClassifyResult(
            merchant=rr.merchant,
            category=cat,
            matched_brand="",
            reason=f"AI判定: {ai.get('reason', '')} (用工分{ai.get('labor_demand_score', 0)})",
        ))
        # 把用工分挂到merchant对象上方便聚合层使用
        setattr(rr.merchant, "_ai_labor_score", ai.get("labor_demand_score", 0))
    return merged


def labor_score_of(cr: ClassifyResult) -> int:
    """从ClassifyResult获取用工需求分。规则命中的非独立商户固定为0。"""
    if cr.category != Category.INDEPENDENT:
        return 0
    return int(getattr(cr.merchant, "_ai_labor_score", 0) or 0)
