"""集中加载环境变量。

和旧版的关键区别：**缺 key 不再抛异常**。
旧版 _require() 在没配 key 时直接 RuntimeError，服务根本起不来 —— 用户
"部署了但一直没启用"的直接原因。现在改成：照常启动，把缺什么写进
problems()，前端 /api/status 会显示出来并给出免费申请入口。
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")

# 各免费服务的申请入口，缺 key 时直接告诉用户去哪拿
SIGNUP_URLS = {
    "tencent": "https://lbs.qq.com/dev/console/key/manage",
    "amap": "https://console.amap.com/dev/key/app",
    "tianditu": "https://console.tianditu.gov.cn/api/key",
    "zhipu": "https://open.bigmodel.cn/usercenter/apikeys",
    "siliconflow": "https://cloud.siliconflow.cn/account/ak",
    "deepseek": "https://platform.deepseek.com",
}


def _env(name: str, default: str = "") -> str:
    """读环境变量。模板里的 your_xxx_here 占位符视同没填。"""
    val = os.getenv(name, "").strip()
    if not val or val.startswith("your_") or val.endswith("_here"):
        return default
    return val


def _env_int(name: str, default: int) -> int:
    try:
        return int(_env(name, str(default)))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    # --- POI 数据源 ---
    poi_provider: str      # auto / tencent / amap
    tencent_key: str
    amap_backend_key: str
    # --- 地图底图 ---
    map_provider: str      # tianditu / amap / osm
    tianditu_key: str
    # --- AI（可选） ---
    llm_provider: str      # none / zhipu / ollama / siliconflow / deepseek / custom
    llm_api_key: str
    llm_base_url: str
    llm_model: str
    # --- 业务参数 ---
    default_city: str
    labor_threshold: int
    grid_size_m: int
    port: int

    @classmethod
    def load(cls) -> "Settings":
        return cls(
            poi_provider=_env("POI_PROVIDER", "auto").lower(),
            tencent_key=_env("TENCENT_KEY"),
            amap_backend_key=_env("AMAP_BACKEND_KEY"),
            map_provider=_env("MAP_PROVIDER", "tianditu").lower(),
            tianditu_key=_env("TIANDITU_KEY"),
            llm_provider=_env("LLM_PROVIDER", "none").lower(),
            llm_api_key=_env("LLM_API_KEY"),
            llm_base_url=_env("LLM_BASE_URL"),
            llm_model=_env("LLM_MODEL"),
            default_city=_env("DEFAULT_CITY", "长沙"),
            labor_threshold=_env_int("LABOR_THRESHOLD", 60),
            grid_size_m=_env_int("GRID_SIZE_M", 800),
            port=_env_int("PORT", 8000),
        )

    # ---------- 派生信息 ----------

    @property
    def resolved_poi_provider(self) -> str:
        """auto 时哪个 key 配了用哪个，都配了优先腾讯（免费额度大 30 倍）。"""
        if self.poi_provider != "auto":
            return self.poi_provider
        if self.tencent_key:
            return "tencent"
        if self.amap_backend_key:
            return "amap"
        return ""

    @property
    def needs_coordinate_fix(self) -> bool:
        """底图是 WGS-84 系时，GCJ-02 的 POI 坐标必须纠偏，否则偏 500 米。"""
        return self.map_provider in ("tianditu", "osm")

    def describe(self) -> str:
        poi = {"tencent": "腾讯POI", "amap": "高德POI"}.get(
            self.resolved_poi_provider, "未配置POI")
        engine = "规则打分" if self.llm_provider in ("", "none") else f"AI打分({self.llm_provider})"
        base = {"tianditu": "天地图", "amap": "高德瓦片", "osm": "OSM"}.get(
            self.map_provider, self.map_provider)
        return f"{poi} · {engine} · {base}"

    @property
    def is_free_stack(self) -> bool:
        """当前组合是否零成本（不含按量付费的接口）。"""
        return self.llm_provider != "deepseek"

    def problems(self) -> list[str]:
        """返回还差什么。空列表 = 可以直接开跑。"""
        out: list[str] = []

        provider = self.resolved_poi_provider
        if not provider:
            out.append(
                f"未配置 POI 数据源。推荐腾讯位置服务（个人免费 10,000 次/日）："
                f"申请 key → {SIGNUP_URLS['tencent']}，填进 .env 的 TENCENT_KEY"
            )
        elif provider == "tencent" and not self.tencent_key:
            out.append(f"POI_PROVIDER=tencent 但没填 TENCENT_KEY → {SIGNUP_URLS['tencent']}")
        elif provider == "amap" and not self.amap_backend_key:
            out.append(f"POI_PROVIDER=amap 但没填 AMAP_BACKEND_KEY → {SIGNUP_URLS['amap']}")
        elif provider == "amap":
            out.append(
                "正在用高德 POI：个人开发者只有 10,000 次/月（与 JS API 共享额度）。"
                f"想要更宽松的免费额度可换腾讯（10,000 次/日）→ {SIGNUP_URLS['tencent']}"
            )

        if self.map_provider == "tianditu" and not self.tianditu_key:
            out.append(
                f"底图选了天地图但没填 TIANDITU_KEY（个人免费 10,000 次/日）："
                f"{SIGNUP_URLS['tianditu']}。也可以把 MAP_PROVIDER 改成 amap，免 key 但属非官方瓦片接口。"
            )

        if self.llm_provider not in ("", "none"):
            if self.llm_provider in ("zhipu", "siliconflow", "deepseek") and not self.llm_api_key:
                url = SIGNUP_URLS.get(self.llm_provider, "")
                out.append(f"LLM_PROVIDER={self.llm_provider} 但没填 LLM_API_KEY → {url}")
            if self.llm_provider == "custom" and not (self.llm_base_url and self.llm_model):
                out.append("LLM_PROVIDER=custom 需要同时配置 LLM_BASE_URL 和 LLM_MODEL")
            if self.llm_provider == "deepseek":
                out.append(
                    "DeepSeek 是按量付费的。想零成本可把 LLM_PROVIDER 换成 none（纯规则）、"
                    "zhipu（免费）或 ollama（本地离线）。"
                )

        return out
