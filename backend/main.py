"""FastAPI 主入口：

- GET /                       前端首页（地图）
- GET /api/config             暴露给前端的高德JS API key（含安全密钥）
- POST /api/analyze           输入 {city, region?, max_pages?} 返回商圈热度报告
- GET /static/*               前端静态资源
"""
from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .amap import AmapClient
from .analyzer import build_city_report
from .classifier import Category, RuleClassifier
from .config import Settings
from .deepseek import DeepSeekClassifier, merge_classification

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FRONTEND_DIR = PROJECT_ROOT / "frontend"
BRANDS_FILE = PROJECT_ROOT / "data" / "chain_brands.txt"

settings = Settings.load()
rule_classifier = RuleClassifier(BRANDS_FILE)

app = FastAPI(title="地推商圈分析", version="0.1.0")
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")


class AnalyzeRequest(BaseModel):
    city: str = Field(default_factory=lambda: settings.default_city)
    region: Optional[str] = None
    max_pages: int = Field(default=10, ge=1, le=40)


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(FRONTEND_DIR / "index.html")


@app.get("/api/config")
async def get_config() -> dict:
    """前端启动时拉一次，拿到地图所需的key配置和默认城市。"""
    return {
        "amap_js_key": settings.amap_frontend_key,
        "amap_security_code": settings.amap_frontend_secret,
        "default_city": settings.default_city,
    }


@app.post("/api/analyze")
async def analyze(req: AnalyzeRequest) -> dict:
    log.info("开始分析 city=%s region=%s max_pages=%d", req.city, req.region, req.max_pages)

    # 1) 抓POI
    async with AmapClient(settings.amap_backend_key) as amap:
        merchants = await amap.search_restaurants(
            req.city,
            region=req.region,
            max_pages=req.max_pages,
        )
    log.info("高德返回 %d 家POI", len(merchants))
    if not merchants:
        raise HTTPException(status_code=404, detail="该区域未返回任何餐饮POI，请检查城市/区域名是否正确")

    # 2) 规则层快速分类
    rule_results = [rule_classifier.classify(m) for m in merchants]
    unknown_indexes = [i for i, r in enumerate(rule_results) if r.category == Category.UNKNOWN]
    log.info("规则层命中 %d / 待AI判断 %d",
             len(rule_results) - len(unknown_indexes), len(unknown_indexes))

    # 3) AI 对UNKNOWN批量判定
    ai_results: list[dict] = []
    if unknown_indexes:
        unknown_merchants = [merchants[i] for i in unknown_indexes]
        ds = DeepSeekClassifier(
            settings.deepseek_api_key,
            model=settings.deepseek_model,
            base_url=settings.deepseek_base_url,
        )
        ai_results = await ds.classify_batch(unknown_merchants)
        log.info("AI 返回 %d 条结果", len(ai_results))

    # 4) 合并
    merged = merge_classification(rule_results, ai_results)

    # 5) 对"独立餐饮"再单独跑一次AI给用工分（规则命中的非独立不需要）
    # 优化：上一步AI已经给了用工分。规则命中的独立(几乎没有)我们再补一次。
    independents_without_score = [
        m.merchant for m in merged
        if m.category == Category.INDEPENDENT and not getattr(m.merchant, "_ai_labor_score", None)
    ]
    if independents_without_score:
        ds = DeepSeekClassifier(
            settings.deepseek_api_key,
            model=settings.deepseek_model,
            base_url=settings.deepseek_base_url,
        )
        extra = await ds.classify_batch(independents_without_score)
        for m, info in zip(independents_without_score, extra):
            setattr(m, "_ai_labor_score", info.get("labor_demand_score", 0))

    # 6) 聚合
    report = build_city_report(
        req.city,
        req.region,
        merged,
        total_pois=len(merchants),
    )
    log.info("聚合输出 %d 个商圈，高需求店共 %d 家",
             len(report.areas), report.high_demand_total)
    return report.to_dict()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host="0.0.0.0", port=settings.port, reload=True)
