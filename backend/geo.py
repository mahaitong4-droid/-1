"""坐标系转换：GCJ-02（火星坐标）↔ WGS-84。

为什么需要：
- 高德/腾讯返回的 POI 坐标是 GCJ-02
- 天地图(CGCS2000≈WGS-84)/OSM 的瓦片是 WGS-84
把 GCJ-02 的点直接画到 WGS-84 底图上，在国内会有 300~600 米的偏移。
所以后端在输出报告前，按当前底图统一把坐标转好，前端不做任何转换。
"""
from __future__ import annotations

import math

__all__ = ["out_of_china", "gcj02_to_wgs84", "wgs84_to_gcj02"]

# 克拉索夫斯基椭球参数（GCJ-02 加密算法沿用）
_A = 6378245.0            # 长半轴
_EE = 0.00669342162296594323  # 偏心率平方
_PI = math.pi
_X_PI = _PI * 3000.0 / 180.0  # 保留给百度坐标扩展用


def out_of_china(lng: float, lat: float) -> bool:
    """粗略判断是否在中国境外。境外不做偏移（GCJ-02 只在境内生效）。"""
    return not (73.66 < lng < 135.05 and 3.86 < lat < 53.55)


def _transform_lat(lng: float, lat: float) -> float:
    ret = (-100.0 + 2.0 * lng + 3.0 * lat + 0.2 * lat * lat
           + 0.1 * lng * lat + 0.2 * math.sqrt(abs(lng)))
    ret += (20.0 * math.sin(6.0 * lng * _PI) + 20.0 * math.sin(2.0 * lng * _PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(lat * _PI) + 40.0 * math.sin(lat / 3.0 * _PI)) * 2.0 / 3.0
    ret += (160.0 * math.sin(lat / 12.0 * _PI) + 320 * math.sin(lat * _PI / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lng(lng: float, lat: float) -> float:
    ret = (300.0 + lng + 2.0 * lat + 0.1 * lng * lng
           + 0.1 * lng * lat + 0.1 * math.sqrt(abs(lng)))
    ret += (20.0 * math.sin(6.0 * lng * _PI) + 20.0 * math.sin(2.0 * lng * _PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(lng * _PI) + 40.0 * math.sin(lng / 3.0 * _PI)) * 2.0 / 3.0
    ret += (150.0 * math.sin(lng / 12.0 * _PI) + 300.0 * math.sin(lng / 30.0 * _PI)) * 2.0 / 3.0
    return ret


def _offset(lng: float, lat: float) -> tuple[float, float]:
    """计算 WGS-84 点在 GCJ-02 下的经纬度偏移量。"""
    d_lat = _transform_lat(lng - 105.0, lat - 35.0)
    d_lng = _transform_lng(lng - 105.0, lat - 35.0)
    rad_lat = lat / 180.0 * _PI
    magic = math.sin(rad_lat)
    magic = 1 - _EE * magic * magic
    sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((_A * (1 - _EE)) / (magic * sqrt_magic) * _PI)
    d_lng = (d_lng * 180.0) / (_A / sqrt_magic * math.cos(rad_lat) * _PI)
    return d_lng, d_lat


def wgs84_to_gcj02(lng: float, lat: float) -> tuple[float, float]:
    """WGS-84 → GCJ-02。"""
    if out_of_china(lng, lat):
        return lng, lat
    d_lng, d_lat = _offset(lng, lat)
    return lng + d_lng, lat + d_lat


def gcj02_to_wgs84(lng: float, lat: float) -> tuple[float, float]:
    """GCJ-02 → WGS-84。

    GCJ-02 的加密没有解析逆函数，这里用两次迭代逼近（误差 < 0.1 米，
    远小于 POI 本身的定位精度，够用）。
    """
    if out_of_china(lng, lat):
        return lng, lat
    # 一次粗解
    d_lng, d_lat = _offset(lng, lat)
    wgs_lng, wgs_lat = lng - d_lng, lat - d_lat
    # 迭代修正：用粗解重新算偏移，消掉一阶残差
    for _ in range(3):
        d_lng, d_lat = _offset(wgs_lng, wgs_lat)
        wgs_lng, wgs_lat = lng - d_lng, lat - d_lat
    return wgs_lng, wgs_lat
