-- 공간 타입과 함수를 쓰려면 PostGIS 확장을 먼저 켠다.
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE buildings (
    id            BIGSERIAL PRIMARY KEY,
    -- 원천 데이터의 고유 ID. 같은 건물을 다시 적재해도 중복되지 않게 (source, source_id)로 유니크를 건다.
    source        TEXT        NOT NULL,              -- 'osm' 지금은 OSM, 나중에 'vworld' 추가
    source_id     TEXT        NOT NULL,
    -- 건물 윤곽. SRID 4326 = 위경도(WGS84). 타일 좌표 변환은 조회할 때 한다.
    geom          geometry(MultiPolygon, 4326) NOT NULL,
    height_m      REAL        NOT NULL,
    -- 높이가 실제 값인지 추정값인지 구분한다. 화면에서 추정 건물을 다르게 표현하기 위한 근거.
    height_source TEXT        NOT NULL CHECK (height_source IN ('measured', 'levels', 'default')),
    data_version  TEXT        NOT NULL,              -- 어느 적재 회차의 데이터인지 (버전 전환·롤백용)
    UNIQUE (source, source_id)
);

-- 공간 인덱스. "이 타일 영역과 겹치는 건물"을 찾을 때 전체를 훑지 않게 한다.
-- 나중에 이 인덱스가 있을 때와 없을 때를 EXPLAIN ANALYZE로 비교하는 것이 측정 과제다.
CREATE INDEX buildings_geom_gist ON buildings USING GIST (geom);
