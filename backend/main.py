"""FastAPI 主入口：

- GET  /             前端首页（地图）
- GET  /api/config   前端地图所需配置（底图类型 + 天地图key + 默认城市）
- GET  /api/status   当前跑在什么组合上、还缺什么 key
- POST /api/analyze  输入 {city, region?, budget?} 返回商圈热度报告
- GET  /static/*     前端静态资源
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .analyzer import build_city_report
from .classifier import Category, ClassifyResult, RuleClassifier
from .config import Settings
from .geo import gcj02_to_wgs84
from .llm import build_llm_client
from .poi import POIAuthError, POIError, POIQuotaError, build_poi_provider
from .scorer import RuleScorer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FRONTEND_DIR = PROJECT_ROOT / "frontend"
BRANDS_FILE = PROJECT_ROOT / "data" / "chain_brands.txt"
LABOR_FILE = PROJECT_ROOT / "data" / "labor_keywords.txt"

VERSION = "0.2.0"

settings = Settings.load()
rule_classifier = RuleClassifier(BRANDS_FILE)
scorer = RuleScorer(LABOR_FILE)

@asynccontextmanager
async def lifespan(_app: FastAPI):
    log.info("地推商圈分析 v%s 已启动 —— 当前组合: %s", VERSION, settings.describe())
    problems = settings.problems()
    if problems:
        log.warning("有 %d 项待处理（服务照常运行，网页上也会提示）:", len(problems))
        for p in problems:
            log.warning("  · %s", p)
    else:
        log.info("配置齐全，打开 http://localhost:%d 即可开跑", settings.port)
    yield


app = FastAPI(title="地推商圈分析", version=VERSION, lifespan=lifespan)
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")


class AnalyzeRequest(BaseModel):
    city: str = Field(default_factory=lambda: settings.default_city)
    region: Optional[str] = None
    # 本次分析最多发起多少次 POI 接口请求（前端"抓取深度"映射过来）
    budget: int = Field(default=30, ge=4, le=200)


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(FRONTEND_DIR / "index.html")


@app.get("/api/config")
async def get_config() -> dict:
    """前端启动时拉一次，拿到底图配置和默认城市。"""
    return {
        "map_provider": settings.map_provider,
        "tianditu_key": settings.tianditu_key,
        "default_city": settings.default_city,
        # 底图是 WGS-84 系时后端已经把坐标纠偏过了，前端不用再动
        "coords": "wgs84" if settings.needs_coordinate_fix else "gcj02",
    }


@app.get("/api/status")
async def get_status() -> dict:
    """当前跑在什么组合上、零成本与否、还缺什么。"""
    problems = settings.problems()
    return {
        "version": VERSION,
        "mode": settings.describe(),
        "free": settings.is_free_stack,
        "ready": bool(settings.resolved_poi_provider),
        "poi_provider": settings.resolved_poi_provider,
        "llm_provider": settings.llm_provider,
        "map_provider": settings.map_provider,
        "default_city": settings.default_city,
        "threshold": settings.labor_threshold,
        "problems": problems,
    }


def _resolve_categories(
    rule_results: list[ClassifyResult],
    unknown_idx: list[int],
    verdicts: list,
) -> None:
    """把 AI 判定合并回规则结果（就地改）。没有 AI 时按独立餐饮处理。"""
    for slot, idx in enumerate(unknown_idx):
        cr = rule_results[idx]
        if verdicts:
            v = verdicts[slot]
            try:
                cr.category = Category(v.category)
            except ValueError:
                cr.category = Category.INDEPENDENT
            cr.merchant.labor_score = v.labor_score
            cr.merchant.labor_reason = v.reason
            cr.reason = v.reason
        else:
            # 规则模式：连锁/奶茶/卤味已被词库剔除，剩下的就是独立餐饮
            cr.category = Category.INDEPENDENT


@app.post("/api/analyze")
async def analyze(req: AnalyzeRequest) -> dict:
    log.info("开始分析 city=%s region=%s budget=%d", req.city, req.region, req.budget)

    # 1) 抓 POI
    try:
        provider = build_poi_provider(settings)
    except POIAuthError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    try:
        async with provider:
            merchants = await provider.search_restaurants(
                req.city, region=req.region, budget=req.budget
            )
    except POIQuotaError as e:
        raise HTTPException(status_code=429, detail=str(e)) from e
    except POIAuthError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except POIError as e:
        raise HTTPException(status_code=502, detail=f"POI 数据源出错: {e}") from e

    log.info("%s 返回 %d 家 POI", provider.name, len(merchants))
    if not merchants:
        raise HTTPException(
            status_code=404,
            detail="该区域没有返回任何餐饮 POI。检查一下城市/区域名是否写对"
                   "（区域要填区县名，如「雨花区」）。",
        )

    # 2) 规则层快速分类（连锁/奶茶/卤味）
    rule_classifier.reload_if_changed()
    rule_results = [rule_classifier.classify(m) for m in merchants]
    unknown_idx = [i for i, r in enumerate(rule_results) if r.category == Category.UNKNOWN]
    log.info("规则层命中 %d / 待定 %d", len(rule_results) - len(unknown_idx), len(unknown_idx))

    # 3) 可选的 AI 二次分类 + 评分（LLM_PROVIDER=none 时整段跳过，零成本）
    verdicts = []
    try:
        llm = build_llm_client(settings)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    if llm is not None and unknown_idx:
        log.info("调用 AI: %s，共 %d 家待判", llm.label, len(unknown_idx))
        async with llm:
            verdicts = await llm.classify(
                [merchants[i] for i in unknown_idx], scorer
            )

    _resolve_categories(rule_results, unknown_idx, verdicts)

    # 4) 用工需求打分：AI 没给分的（含规则模式下的全部）走规则引擎
    unscored = [
        cr.merchant for cr in rule_results
        if cr.category == Category.INDEPENDENT and not cr.merchant.labor_score
    ]
    if unscored:
        scorer.apply(unscored)
    log.info("打分完成，独立餐饮 %d 家",
             sum(1 for r in rule_results if r.category == Category.INDEPENDENT))

    # 5) 坐标纠偏：POI 是 GCJ-02，天地图/OSM 底图是 WGS-84，不转会偏 500 米
    if settings.needs_coordinate_fix:
        for m in merchants:
            m.lng, m.lat = gcj02_to_wgs84(m.lng, m.lat)

    # 6) 聚合
    report = build_city_report(
        req.city,
        req.region,
        rule_results,
        total_pois=len(merchants),
        threshold=settings.labor_threshold,
        grid_size_m=settings.grid_size_m,
        engine=settings.describe(),
    )
    log.info("聚合输出 %d 个商圈，高需求店共 %d 家",
             len(report.areas), report.high_demand_total)
    return report.to_dict()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host="0.0.0.0", port=settings.port, reload=True)
