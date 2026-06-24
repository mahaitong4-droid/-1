"""集中加载环境变量。"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")


def _require(name: str) -> str:
    val = os.getenv(name, "").strip()
    if not val or val.startswith("your_"):
        raise RuntimeError(
            f"环境变量 {name} 未配置。请复制 .env.example 为 .env 并填入真实key。"
        )
    return val


@dataclass(frozen=True)
class Settings:
    amap_backend_key: str
    amap_frontend_key: str
    amap_frontend_secret: str
    deepseek_api_key: str
    deepseek_model: str
    deepseek_base_url: str
    default_city: str
    port: int

    @classmethod
    def load(cls) -> "Settings":
        return cls(
            amap_backend_key=_require("AMAP_BACKEND_KEY"),
            amap_frontend_key=_require("AMAP_FRONTEND_KEY"),
            amap_frontend_secret=os.getenv("AMAP_FRONTEND_SECRET", "").strip(),
            deepseek_api_key=_require("DEEPSEEK_API_KEY"),
            deepseek_model=os.getenv("DEEPSEEK_MODEL", "deepseek-chat"),
            deepseek_base_url=os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com"),
            default_city=os.getenv("DEFAULT_CITY", "长沙"),
            port=int(os.getenv("PORT", "8000")),
        )


settings = Settings.load() if os.getenv("AMAP_BACKEND_KEY") else None  # 延迟到 main 加载也行
