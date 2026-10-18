-- 도로·보행로. 선(LineString)이라 건물·물과 테이블을 나눈다.
-- kind는 화면 굵기 등급(major/street/service/path), width_m은 화면 폭 기준값(실측 아님).
CREATE TABLE roads (
    id           BIGSERIAL PRIMARY KEY,
    source       TEXT        NOT NULL,
    source_id    TEXT        NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN ('major', 'street', 'service', 'path')),
    width_m      REAL        NOT NULL CHECK (width_m > 0 AND width_m < 60),
    name         TEXT,
    geom         geometry(MultiLineString, 4326) NOT NULL,
    data_version TEXT        NOT NULL,
    loaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source, source_id)
);
CREATE INDEX roads_geom_gist ON roads USING GIST (geom);
