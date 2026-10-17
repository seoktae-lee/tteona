#!/bin/bash
# 사용법: gist-bench.sh  (map-api 폴더에서 실행)
PSQL="docker compose exec -T postgis psql -U mapapi -d mapapi -tA"
TILE_SQL="WITH bounds AS (SELECT ST_TileEnvelope(16,55898,25384) AS geom), features AS (SELECT ST_AsMVTGeom(ST_Transform(b.geom,3857), bounds.geom) AS geom, b.height_m, b.height_source FROM buildings b, bounds WHERE b.geom && ST_Transform(bounds.geom,4326)) SELECT ST_AsMVT(features.*,'buildings') FROM features"
run() { # $1 라벨, 7회 실행해 Execution Time 중앙값과 계획 요약
  for i in $(seq 1 7); do $PSQL -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $TILE_SQL" | python3 -c "import json,sys;p=json.load(sys.stdin)[0];print(p['Execution Time'])"; done | sort -n | awk -v l="$1" '{a[NR]=$1} END{printf "%s median=%.3fms min=%.3f max=%.3f\n", l, a[4], a[1], a[7]}'
  $PSQL -c "EXPLAIN $TILE_SQL" | grep -oE '(Seq Scan|Index Scan|Bitmap Index Scan|Bitmap Heap Scan) on [a-z_]+' | sort -u | tr '\n' ';'; echo
}
echo "rows: $($PSQL -c 'select count(*) from buildings')"
run "145동 + GiST"
$PSQL -c "DROP INDEX buildings_geom_gist" >/dev/null; run "145동, 인덱스 없음"; $PSQL -c "CREATE INDEX buildings_geom_gist ON buildings USING GIST (geom)" >/dev/null
# 합성: 성수 블록 145동을 40x40 격자로 복제 (약 14x21km)
$PSQL -c "INSERT INTO buildings (source, source_id, geom, height_m, height_source, data_version)
 SELECT 'synthetic', b.source_id||'-'||gx||'-'||gy, ST_Translate(b.geom, (gx-20)*0.0045, (gy-20)*0.0050), b.height_m, b.height_source, 'synthetic-bench'
 FROM buildings b, generate_series(0,39) gx, generate_series(0,39) gy WHERE b.source='osm' AND NOT (gx=20 AND gy=20); ANALYZE buildings;" >/dev/null
echo "rows: $($PSQL -c 'select count(*) from buildings')"
run "합성 + GiST"
$PSQL -c "DROP INDEX buildings_geom_gist" >/dev/null; $PSQL -c "ANALYZE buildings" >/dev/null; run "합성, 인덱스 없음"
# 정리: VACUUM은 트랜잭션 블록 안에서 실행할 수 없어 명령을 나눈다(한 -c에 묶으면 전체가 취소됨)
$PSQL -c "DELETE FROM buildings WHERE source='synthetic'" >/dev/null
$PSQL -c "CREATE INDEX IF NOT EXISTS buildings_geom_gist ON buildings USING GIST (geom)" >/dev/null
$PSQL -c "VACUUM ANALYZE buildings" >/dev/null
echo "cleanup rows: $($PSQL -c 'select count(*) from buildings')  index: $($PSQL -c "select count(*) from pg_indexes where indexname='buildings_geom_gist'")"
