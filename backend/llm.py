"""可选的 AI 增强层：对规则层判不准的商户做二次分类 + 用工需求评分。

设计要点：
1. 只用 OpenAI 兼容的 /chat/completions 一个端点，直接 httpx 调用，
   所以 DeepSeek / 智谱 / 硅基流动 / 本地 Ollama 走的是同一条代码路径，
   换供应商只改 .env 一行，不用改代码、不用装 SDK。
2. **任何失败都回落到规则打分器**，而不是给 0 分。
   （旧版本 AI 一超时，整批店铺的用工分全变 0，等于白抓。）
3. 默认 LLM_PROVIDER=none，一行 AI 都不调，纯靠 scorer.py，零成本。
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass

import httpx

from .classifier import Category
from .poi import Merchant
from .scorer import RuleScorer

log = logging.getLogger(__name__)

__all__ = ["LLMVerdict", "LLMClient", "PROVIDER_PRESETS", "build_llm_client"]


@dataclass(frozen=True)
class Preset:
    base_url: str
    model: str
    json_mode: bool
    needs_key: bool
    label: str


# 免费额度情况见 README。GLM-4.5-Flash 已于 2026-01 下线并路由到 glm-4.7-flash，
# 这里直接写新的模型 ID。
PROVIDER_PRESETS: dict[str, Preset] = {
    "zhipu": Preset(
        "https://open.bigmodel.cn/api/paas/v4", "glm-4.7-flash",
        True, True, "智谱 GLM-4.7-Flash（免费）",
    ),
    "ollama": Preset(
        "http://localhost:11434/v1", "qwen3:8b",
        True, False, "本地 Ollama（离线免费）",
    ),
    "siliconflow": Preset(
        "https://api.siliconflow.cn/v1", "Qwen/Qwen3-8B",
        True, True, "硅基流动 Qwen3-8B（免费额度）",
    ),
    "deepseek": Preset(
        "https://api.deepseek.com", "deepseek-chat",
        True, True, "DeepSeek（按量付费）",
    ),
    "custom": Preset("", "", True, False, "自定义 OpenAI 兼容端点"),
}


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


@dataclass
class LLMVerdict:
    category: str
    labor_score: int
    reason: str
    from_ai: bool = True


class LLMClient:
    """OpenAI 兼容端点的极简客户端。只需要 /chat/completions。"""

    def __init__(
        self,
        api_key: str,
        base_url: str,
        model: str,
        *,
        json_mode: bool = True,
        label: str = "",
        timeout: float = 120.0,
    ):
        self._key = api_key or "not-needed"
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._json_mode = json_mode
        self.label = label or model
        self._client = httpx.AsyncClient(timeout=timeout)

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "LLMClient":
        return self

    async def __aexit__(self, *_exc) -> None:
        await self.aclose()

    async def classify(
        self,
        merchants: list[Merchant],
        fallback: RuleScorer,
        *,
        batch_size: int = 20,
        concurrency: int = 3,
    ) -> list[LLMVerdict]:
        """批量判定。返回与 merchants 等长、顺序一致的结果。

        任何一批失败 → 该批逐条用 fallback 规则打分，而不是判 0 分。
        """
        if not merchants:
            return []

        batches = [merchants[i:i + batch_size] for i in range(0, len(merchants), batch_size)]
        results: list[list[LLMVerdict]] = [[] for _ in batches]
        sem = asyncio.Semaphore(concurrency)
        failures = 0

        async def _run(idx: int, batch: list[Merchant]) -> None:
            nonlocal failures
            async with sem:
                try:
                    results[idx] = await self._call_once(batch)
                except Exception as e:
                    failures += 1
                    log.warning("AI 第 %d 批失败，回落规则打分: %s", idx, e)
                    results[idx] = self._fallback_batch(batch, fallback)

        await asyncio.gather(*[_run(i, b) for i, b in enumerate(batches)])
        if failures:
            log.warning("共 %d/%d 批走了规则兜底", failures, len(batches))

        flat: list[LLMVerdict] = []
        for sub in results:
            flat.extend(sub)
        return flat

    @staticmethod
    def _fallback_batch(batch: list[Merchant], fallback: RuleScorer) -> list[LLMVerdict]:
        out = []
        for m in batch:
            b = fallback.score(m)
            out.append(LLMVerdict(
                category=Category.INDEPENDENT.value,
                labor_score=b.score,
                reason=f"AI不可用，规则估分: {b.reason}",
                from_ai=False,
            ))
        return out

    async def _call_once(self, batch: list[Merchant]) -> list[LLMVerdict]:
        payload_items = [
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
        body: dict = {
            "model": self._model,
            "temperature": 0.0,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": "请处理以下商户列表，并按要求输出。返回JSON对象，"
                               "键名为items，值为数组：\n"
                               + json.dumps(payload_items, ensure_ascii=False),
                },
            ],
        }
        if self._json_mode:
            body["response_format"] = {"type": "json_object"}

        resp = await self._client.post(
            f"{self._base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {self._key}",
                "Content-Type": "application/json",
            },
            json=body,
        )
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()
        try:
            text = data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError) as e:
            raise RuntimeError(f"响应结构异常: {str(data)[:200]}") from e
        return self._parse_response(text, len(batch))

    @staticmethod
    def _parse_response(text: str, expected_len: int) -> list[LLMVerdict]:
        text = (text or "").strip()
        # 兼容模型偶尔加 ```json ... ``` 包裹
        if text.startswith("```"):
            text = text.strip("`")
            if text.lower().startswith("json"):
                text = text[4:].lstrip()
        # 兼容 qwen3 之类会先吐 <think>...</think> 的推理模型
        if "</think>" in text:
            text = text.split("</think>", 1)[1].strip()
        try:
            obj = json.loads(text)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"AI返回非JSON: {text[:200]}") from e

        items = obj.get("items") if isinstance(obj, dict) else obj
        if isinstance(obj, dict) and not isinstance(items, list):
            # 有的模型会把数组套在别的键名下，兜底取第一个 list 值
            items = next((v for v in obj.values() if isinstance(v, list)), None)
        if not isinstance(items, list):
            raise RuntimeError(f"AI返回格式错误: {text[:200]}")

        out = [
            LLMVerdict(Category.UNKNOWN.value, 0, "", from_ai=True)
            for _ in range(expected_len)
        ]
        for it in items:
            if not isinstance(it, dict):
                continue
            idx = it.get("index")
            if not isinstance(idx, int) or not (0 <= idx < expected_len):
                continue
            try:
                score = max(0, min(100, int(it.get("labor_demand_score", 0))))
            except (TypeError, ValueError):
                score = 0
            out[idx] = LLMVerdict(
                category=it.get("category") or Category.UNKNOWN.value,
                labor_score=score,
                reason=str(it.get("reason") or "")[:60],
            )
        return out


def build_llm_client(settings) -> LLMClient | None:
    """按配置构造 LLM 客户端。LLM_PROVIDER=none（默认）时返回 None。"""
    choice = (settings.llm_provider or "none").lower()
    if choice in ("", "none", "off", "false"):
        return None

    preset = PROVIDER_PRESETS.get(choice)
    if preset is None:
        raise ValueError(
            f"未知的 LLM_PROVIDER={choice!r}。可选: none / "
            + " / ".join(PROVIDER_PRESETS)
        )

    base_url = (settings.llm_base_url or preset.base_url).strip()
    model = (settings.llm_model or preset.model).strip()
    if not base_url:
        raise ValueError(f"LLM_PROVIDER={choice} 需要同时配置 LLM_BASE_URL")
    if not model:
        raise ValueError(f"LLM_PROVIDER={choice} 需要同时配置 LLM_MODEL")
    if preset.needs_key and not settings.llm_api_key:
        raise ValueError(f"LLM_PROVIDER={choice} 需要配置 LLM_API_KEY")

    return LLMClient(
        settings.llm_api_key,
        base_url,
        model,
        json_mode=preset.json_mode,
        label=f"{preset.label} · {model}",
    )
