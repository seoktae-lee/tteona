# 데이터 출처

`osm-seongsu-2026-10-11.json`: 성수동 일대(bbox 127.055,37.5405,127.059,37.5452) 건물 145동.
2026-10-11 OpenStreetMap API에서 한 번 조회해 앱 시안용 로컬 좌표(1단위 = 10m)로 변환한 스냅샷이다.

© OpenStreetMap contributors, [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
이 데이터와 이를 가공한 DB·타일에도 같은 라이선스가 적용된다. 재배포 시 출처와 라이선스를 함께 표기한다.

`osm-jamsil-2026-10-18.geojson`: 잠실 롯데월드타워·석촌호수 일대(bbox 37.5040,127.0930,37.5170,127.1120). `scripts/fetch_osm.py`로 2026-10-18 Overpass에서 한 번 조회.
건물 1,420(높이 실측 265 · 층수 기반 78 · 기본값 1,077, 롯데월드타워는 building:part 조각), 물 2(석촌호수 relation 9856886 포함).
© OpenStreetMap contributors, ODbL 1.0.
