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
- 물은 natural=water 의 닫힌 way와 multipolygon relation을 쓴다. relation은 잘린 멤버 선을 이어 고리를 만든다.
데이터: © OpenStreetMap contributors, ODbL 1.0
"""
import argparse
import json
import re
import sys
import subprocess
import time
from datetime import date
from pathlib import Path

SERVERS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]
UA = "tteona-map-api/0.1 (one-time regional snapshot)"
DEFAULT_HEIGHT = {"apartments": 36.0}
FALLBACK_HEIGHT = 10.0
LEVEL_HEIGHT = 3.2


# 도로 등급 → (화면 등급, 화면 폭 m). 폭은 지도 표현용 기준값이지 실측이 아니다.
ROAD_CLASS = {
    "motorway": ("major", 18), "trunk": ("major", 18), "primary": ("major", 14), "secondary": ("major", 11),
    "tertiary": ("street", 9), "residential": ("street", 6.5), "unclassified": ("street", 6.5),
    "living_street": ("street", 5), "pedestrian": ("path", 5), "service": ("service", 4.5),
    "footway": ("path", 2.2), "path": ("path", 2.2), "cycleway": ("path", 2.2), "steps": ("path", 2.2),
}
for k in ("motorway_link", "trunk_link", "primary_link", "secondary_link"):
    ROAD_CLASS[k] = ("major", 8)
ROAD_CLASS["tertiary_link"] = ("street", 6.5)


def query(bbox: str) -> dict:
    # "out geom tags"는 relation의 구성원(members)을 빼고 태그만 준다 → 호수 relation이 비어 있었다(2026-10-18). body(기본) 출력을 쓴다.
    q = f"""[out:json][timeout:120];
(
  way["building"]({bbox});
  way["building:part"]({bbox});
  way["natural"="water"]({bbox});
  relation["natural"="water"]({bbox});
  way["highway"]({bbox});
);
out geom;"""
    # 조회는 curl로 한다. 일부 환경(예: Xcode 내장 Python 3.9)의 오래된 TLS 라이브러리는
    # overpass-api.de와 SSL 핸드셰이크에 실패한다(2026-10-18 확인). curl은 시스템 TLS를 쓴다.
    wait = 15
    for attempt in range(6):
        url = SERVERS[attempt % len(SERVERS)]
        r = subprocess.run(["curl", "-sS", "-m", "180", "-A", UA, "--data-urlencode", f"data={q}", url],
                           capture_output=True, text=True)
        body = r.stdout
        if r.returncode == 0 and body.lstrip().startswith("{"):
            return json.loads(body)
        reason = (r.stderr or body[:80]).strip().splitlines()[0] if (r.stderr or body) else f"exit {r.returncode}"
        print(f"  조회 실패({url.split('/')[2]}): {reason[:80]} → {wait}초 뒤 재시도", file=sys.stderr)
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


def assemble_rings(lines):
    """잘린 선(way) 조각들을 끝점끼리 이어 닫힌 고리들로 만든다. 닫히지 않는 조각은 버린다."""
    pending = [[(p["lon"], p["lat"]) for p in g] for g in lines if len(g) >= 2]
    rings = []
    while pending:
        cur = pending.pop(0)
        progressed = True
        while cur[0] != cur[-1] and progressed:
            progressed = False
            for i, seg in enumerate(pending):
                if seg[0] == cur[-1]:
                    cur += seg[1:]
                elif seg[-1] == cur[-1]:
                    cur += seg[::-1][1:]
                elif seg[-1] == cur[0]:
                    cur = seg[:-1] + cur
                elif seg[0] == cur[0]:
                    cur = seg[::-1][:-1] + cur
                else:
                    continue
                pending.pop(i)
                progressed = True
                break
        if cur[0] == cur[-1] and len(cur) >= 4:
            rings.append([[round(x, 7), round(y, 7)] for x, y in cur])
    return rings


def inside(point, ring):
    """점이 고리 안에 있는지(짝홀 규칙). 섬(inner)이 어느 호수(outer)에 속하는지 정하는 데 쓴다."""
    x, y = point
    hit = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def water_features(e):
    t = e["tags"]
    if e["type"] == "way":
        r = ring(e.get("geometry", []))
        polys = [[r]] if r else []
    else:  # multipolygon relation: 조각난 멤버 선을 이어 붙여 고리를 만들고, 섬은 들어 있는 호수에 구멍으로 단다
        members = e.get("members", [])
        outers = assemble_rings([m.get("geometry", []) for m in members if m.get("role") == "outer"])
        inners = assemble_rings([m.get("geometry", []) for m in members if m.get("role") == "inner"])
        polys = [[o] + [i for i in inners if inside(i[0], o)] for o in outers]
    return [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": p},
             "properties": {"kind": "water", "id": f"{e['type'][0]}{e['id']}-{i}", "name": t.get("name")}}
            for i, p in enumerate(polys)]


def road_feature(e):
    t = e["tags"]
    cls = ROAD_CLASS.get(t.get("highway"))
    # 지하(터널·지하도)와 실내 통로는 지도 위에 보이지 않으므로 뺀다.
    if not cls or t.get("tunnel") in ("yes", "building_passage") or t.get("indoor") == "yes" or t.get("layer", "0").startswith("-"):
        return None
    pts = [[round(p["lon"], 7), round(p["lat"], 7)] for p in e.get("geometry", [])]
    if len(pts) < 2:
        return None
    kind, width = cls
    return {"type": "Feature", "geometry": {"type": "LineString", "coordinates": pts},
            "properties": {"kind": "road", "id": str(e["id"]), "road_kind": kind, "width_m": width, "name": t.get("name")}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--bbox", required=True, help="south,west,north,east")
    ap.add_argument("--out", default="data")
    ap.add_argument("--layers", default="buildings,water,roads",
                    help="받을 종류(쉼표). 이미 다른 방식으로 건물을 넣은 지역은 water,roads 만")
    a = ap.parse_args()
    raw = query(a.bbox)
    feats, skipped = [], 0
    want = set(a.layers.split(","))
    for e in raw["elements"]:
        t = e.get("tags", {})
        if t.get("natural") == "water":
            if "water" in want:
                feats += water_features(e)
        elif e["type"] == "way" and "highway" in t:
            r = road_feature(e) if "roads" in want else None
            if r:
                feats.append(r)
        elif e["type"] == "way" and ("building" in t or "building:part" in t) and "buildings" in want:
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
        key = f"building/{p['height_source']}" if p["kind"] == "building" else (f"road/{p['road_kind']}" if p["kind"] == "road" else p["kind"])
        kinds[key] = kinds.get(key, 0) + 1
    print(f"{out}: {len(feats)}개 {kinds}, 버림 {skipped}")


if __name__ == "__main__":
    main()
