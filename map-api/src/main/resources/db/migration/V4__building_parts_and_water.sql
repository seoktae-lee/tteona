-- 건물 조각(OSM building:part)은 공중에서 시작할 수 있다(예: 롯데월드타워 상층부). 시작 높이를 저장한다.
ALTER TABLE buildings ADD COLUMN min_height_m REAL NOT NULL DEFAULT 0;
ALTER TABLE buildings ADD CONSTRAINT buildings_min_below_height CHECK (min_height_m < height_m);

-- 호수·강 같은 물 영역. 건물과 성격이 달라 테이블을 나눈다(높이 없음).
CREATE TABLE water_areas (
    id           BIGSERIAL PRIMARY KEY,
    source       TEXT        NOT NULL,
    source_id    TEXT        NOT NULL,
    name         TEXT,
    geom         geometry(MultiPolygon, 4326) NOT NULL,
    data_version TEXT        NOT NULL,
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, source_id)
);
CREATE INDEX water_areas_geom_gist ON water_areas USING GIST (geom);
