package kr.tteona.mapapi.building;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import kr.tteona.mapapi.tile.TileCacheEvictor;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;

/**
 * 성수 OSM 스냅샷(앱 번들용 로컬 좌표 JSON)을 buildings 테이블에 적재한다.
 * 같은 파일을 여러 번 적재해도 결과가 같다(멱등). 중복 방지는 DB의 (source, source_id) 유니크 제약이 맡는다.
 */
@Component
public class OsmBuildingImporter {

	// 앱 시안이 쓰던 로컬 좌표의 기준점. 1단위 = 10m, x는 동쪽, z는 남쪽이 +.
	private static final double ORIGIN_LAT = 37.54285;
	private static final double ORIGIN_LON = 127.057;
	private static final double METERS_PER_UNIT = 10;
	private static final double METERS_PER_DEGREE_LAT = 111_320;

	// 이미 있으면 갱신, 없으면 추가. SELECT 후 INSERT와 달리 동시에 두 번 돌아도 중복이 생기지 않는다.
	private static final String UPSERT = """
			INSERT INTO buildings (source, source_id, geom, height_m, height_source, data_version)
			VALUES ('osm', ?, ST_Multi(ST_GeomFromText(?, 4326)), ?, ?, ?)
			ON CONFLICT (source, source_id) DO UPDATE SET
			    geom = EXCLUDED.geom,
			    height_m = EXCLUDED.height_m,
			    height_source = EXCLUDED.height_source,
			    data_version = EXCLUDED.data_version,
			    loaded_at = now()
			""";

	private final JdbcTemplate jdbc;
	private final ObjectMapper mapper;
	private final TileCacheEvictor tileCache;

	public OsmBuildingImporter(JdbcTemplate jdbc, ObjectMapper mapper, TileCacheEvictor tileCache) {
		this.jdbc = jdbc;
		this.mapper = mapper;
		this.tileCache = tileCache;
	}

	/** 전부 성공하거나 전부 취소된다(@Transactional). 중간에 실패해도 반쯤 적재된 상태가 남지 않는다. */
	@Transactional
	public int importFile(Path file) throws IOException {
		JsonNode root = mapper.readTree(Files.readString(file));
		String dataVersion = "osm-" + root.get("fetchedOn").asString();

		List<Object[]> rows = new ArrayList<>();
		for (JsonNode b : root.get("buildings")) {
			rows.add(new Object[] {
					b.get("id").asString(),
					toPolygonWkt(b.get("outline")),
					b.get("height").asDouble() * METERS_PER_UNIT,
					b.get("heightIsEstimated").asBoolean() ? "estimated" : "measured",
					dataVersion });
		}
		// 한 번에 묶어서 보낸다(배치). 145번 왕복하는 것보다 네트워크 비용이 적다.
		jdbc.batchUpdate(UPSERT, rows);
		// 건물이 바뀌었으니 타일 캐시를 비운다. 커밋이 끝난 뒤에 실행되도록 예약만 한다.
		tileCache.evictAllAfterCommit();
		return rows.size();
	}

	/** 로컬 좌표 꼭짓점 목록을 위경도 다각형 WKT로 바꾼다. 다각형은 시작점으로 다시 닫혀야 한다. */
	static String toPolygonWkt(JsonNode outline) {
		List<String> points = new ArrayList<>();
		for (JsonNode p : outline) {
			points.add(toLonLat(p.get("x").asDouble(), p.get("z").asDouble()));
		}
		if (!points.getFirst().equals(points.getLast())) {
			points.add(points.getFirst());
		}
		return "POLYGON((" + String.join(", ", points) + "))";
	}

	private static String toLonLat(double x, double z) {
		double metersPerDegreeLon = METERS_PER_DEGREE_LAT * Math.cos(Math.toRadians(ORIGIN_LAT));
		double lon = ORIGIN_LON + x * METERS_PER_UNIT / metersPerDegreeLon;
		double lat = ORIGIN_LAT - z * METERS_PER_UNIT / METERS_PER_DEGREE_LAT;
		return lon + " " + lat;
	}
}
