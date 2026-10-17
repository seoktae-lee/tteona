-- 부하·인덱스 측정용 합성 데이터. 실제 성수 블록(source='osm') 145동을 40x40 격자로 평행 이동 복제한다.
-- 약 14x21km, 23.2만 동. 실제 도시와 밀도·도형 복잡도가 다르다는 점을 결과 해석에 반영할 것.
-- 넣기:  docker compose exec -T postgis psql -U mapapi -d mapapi -f - < scripts/synthetic-grid.sql
-- 지우기: DELETE FROM buildings WHERE source = 'synthetic'; 그다음 VACUUM ANALYZE buildings; (따로 실행)
INSERT INTO buildings (source, source_id, geom, height_m, height_source, data_version)
SELECT 'synthetic',
       b.source_id || '-' || gx || '-' || gy,
       ST_Translate(b.geom, (gx - 20) * 0.0045, (gy - 20) * 0.0050),
       b.height_m, b.height_source, 'synthetic-bench'
FROM buildings b, generate_series(0, 39) gx, generate_series(0, 39) gy
WHERE b.source = 'osm' AND NOT (gx = 20 AND gy = 20)
ON CONFLICT (source, source_id) DO NOTHING;

ANALYZE buildings;
