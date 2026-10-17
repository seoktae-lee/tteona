-- OSM 성수 원천은 높이가 "추정인지 아닌지"만 알려주고, 층수 기반인지 기본값인지는 구분하지 않는다.
-- 원천에 없는 정보를 지어내지 않도록 'estimated'를 허용한다. V1은 고치지 않고 새 버전으로 바꾼다.
ALTER TABLE buildings DROP CONSTRAINT buildings_height_source_check;
ALTER TABLE buildings ADD CONSTRAINT buildings_height_source_check
    CHECK (height_source IN ('measured', 'levels', 'default', 'estimated'));
