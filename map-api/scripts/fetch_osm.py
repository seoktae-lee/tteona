#!/usr/bin/env python3
"""OSM에서 한 지역의 건물·건물 조각·물(호수/강) 스냅샷을 받아 map-api 적재용 GeoJSON으로 만든다.

사용법:
  python3 scripts/fetch_osm.py --name jamsil --bbox 37.5040,127.0930,37.5170,127.1120

- 공개 Overpass 서버에 한 번만 조회한다(운영 중 반복 호출 금지). 혼잡하면 간격을 늘려 재시도한다.
- 높이 규칙(출처를 함께 기록, 없는 값을 실제처럼 만들지 않는다):
    height 태그 있음          → 그 값, height_source=measured
    building:levels만 있음    → 층수 × 3.2m, height_source=levels
    둘 다 없음                → 아파트 36m, 그 외 10m, height_source=default
- building:part의 min_height(공중에 뜬 조각의 시작 높이)도 남긴다.
- 물은 natural=water 의 닫힌 way와, 멤버가 각각 닫힌 multipolygon relation의 outer/inner를 쓴다.
데이터: © OpenStreetMap contributors, ODbL 1.0
"""
import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

SERVERS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]
UA = "tteona-map-api/0.1 (one-time regional snapshot)"
DEFAULT_HEIGHT = {"apartments": 36.0}
FALLBACK_HEIGHT = 10.0
LEVEL_HEIGHT = 3.2


def query(bbox: str) -> dict:
    q = f"""[out:json][timeout:120];
(
  way["building"]({bbox});
  way["building:part"]({bbox});
  way["natural"="water"]({bbox});
  relation["natural"="water"]({bbox});
);
out geom tags;"""
    wait = 15
    for attempt in range(6):
        url = SERVERS[attempt % len(SERVERS)]
        req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": q}).encode(), headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.load(r)
        except Exception as e:  # 혼잡(502/504/429)·HTML 응답 등
            print(f"  조회 실패({url.split('/')[2]}): {str(e)[:80]} → {wait}초 뒤 재시도", file=sys.stderr)
            time.sleep(wait)
            wait *= 2
    sys.exit("Overpass 조회 실패: 나중에 다시 시도")


def meters(value):
    """'555 meters', '61', '3.5 m' → 숫자. 단위가 피트 등이면 None(추측하지 않음)."""
    if value is None:
        return None
    m = re.match(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*(m|meter|meters|metre|metres)?\s*$", str(value))
    return float(m.group(1)) if m else None


def ring(geometry):
    pts = [[round(p["lon"], 7), round(p["lat"], 7)] for p in geometry]
    if len(pts) < 4 or pts[0] != pts[-1]:
        return None
    return pts


def building_feature(e):
    t = e["tags"]
    outer = ring(e.get("geometry", []))
    if not outer:
        return None
    h, src = meters(t.get("height")), "measured"
    if h is None:
        levels = meters(t.get("building:levels"))
        if levels is not None:
            h, src = round(levels * LEVEL_HEIGHT, 1), "levels"
        else:
            h, src = DEFAULT_HEIGHT.get(t.get("building"), FALLBACK_HEIGHT), "default"
    min_h = meters(t.get("min_height")) or 0.0
    if h <= min_h:
        return None  # 높이가 시작 높이보다 낮은 잘못된 조각은 버린다
    return {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [outer]},
            "properties": {"kind": "building", "id": str(e["id"]), "height_m": h, "min_height_m": min_h,
                           "height_source": src, "part": "building:part" in t}}


def water_features(e):
    t = e["tags"]
    if e["type"] == "way":
        r = ring(e.get("geometry", []))
        polys = [[r]] if r else []
    else:  # multipolygon relation: 각 멤버 way가 스스로 닫힌 경우만(조각 이어 붙이기는 하지 않음)
        outers = [ring(m.get("geometry", [])) for m in e.get("members", []) if m.get("role") == "outer"]
        inners = [ring(m.get("geometry", [])) for m in e.get("members", []) if m.get("role") == "inner"]
        outers = [o for o in outers if o]
        inners = [i for i in inners if i]
        polys = [[o] + inners for o in outers] if len(outers) == 1 else [[o] for o in outers]
    return [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": p},
             "properties": {"kind": "water", "id": f"{e['type'][0]}{e['id']}-{i}", "name": t.get("name")}}
            for i, p in enumerate(polys)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--bbox", required=True, help="south,west,north,east")
    ap.add_argument("--out", default="data")
    a = ap.parse_args()
    raw = query(a.bbox)
    feats, skipped = [], 0
    for e in raw["elements"]:
        t = e.get("tags", {})
        if t.get("natural") == "water":
            feats += water_features(e)
        elif e["type"] == "way" and ("building" in t or "building:part" in t):
            f = building_feature(e)
            if f:
                feats.append(f)
            else:
                skipped += 1
    fc = {"type": "FeatureCollection",
          "metadata": {"source": "osm", "region": a.name, "bbox": a.bbox,
                       "osmBase": raw.get("osm3s", {}).get("timestamp_osm_base"), "fetchedOn": str(date.today()),
                       "attribution": "© OpenStreetMap contributors", "license": "ODbL-1.0"},
          "features": feats}
    out = Path(a.out) / f"osm-{a.name}-{date.today()}.geojson"
    out.write_text(json.dumps(fc, ensure_ascii=False, separators=(",", ":")))
    kinds = {}
    for f in feats:
        p = f["properties"]
        key = p["kind"] if p["kind"] == "water" else f"building/{p['height_source']}"
        kinds[key] = kinds.get(key, 0) + 1
    print(f"{out}: {len(feats)}개 {kinds}, 버림 {skipped}")


if __name__ == "__main__":
    main()
