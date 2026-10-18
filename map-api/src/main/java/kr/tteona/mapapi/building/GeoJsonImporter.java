package kr.tteona.mapapi.building;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import kr.tteona.mapapi.tile.TileCacheEvictor;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;

/**
 * 지역에 상관없는 표준 GeoJSON(scripts/fetch_osm.py 출력)을 적재한다. 건물·물·도로를 함께 받는다.
 * 성수 전용 적재기(OsmBuildingImporter)와 달리 좌표 변환이 없다(이미 위경도).
 * 높이 규칙은 수집 스크립트가 정하고 출처(height_source)를 남긴다. 여기서는 값의 범위만 검사한다.
 */
@Component
public class GeoJsonImporter {

	private static final Set<String> HEIGHT_SOURCES = Set.of("measured", "levels", "default", "estimated");

	private static final String UPSERT_BUILDING = """
			INSERT INTO buildings (source, source_id, geom, height_m, min_height_m, height_source, data_version)
			VALUES ('osm', ?, ST_Multi(ST_GeomFromGeoJSON(?)), ?, ?, ?, ?)
			ON CONFLICT (source, source_id) DO UPDATE SET
			    geom = EXCLUDED.geom, height_m = EXCLUDED.height_m, min_height_m = EXCLUDED.min_height_m,
			    height_source = EXCLUDED.height_source, data_version = EXCLUDED.data_version, loaded_at = now()
			""";

	private static final String UPSERT_WATER = """
			INSERT INTO water_areas (source, source_id, name, geom, data_version)
			VALUES ('osm', ?, ?, ST_Multi(ST_GeomFromGeoJSON(?)), ?)
			ON CONFLICT (source, source_id) DO UPDATE SET
			    name = EXCLUDED.name, geom = EXCLUDED.geom, data_version = EXCLUDED.data_version, loaded_at = now()
			""";

	private static final String UPSERT_ROAD = """
			INSERT INTO roads (source, source_id, kind, width_m, name, geom, data_version)
			VALUES ('osm', ?, ?, ?, ?, ST_Multi(ST_GeomFromGeoJSON(?)), ?)
			ON CONFLICT (source, source_id) DO UPDATE SET
			    kind = EXCLUDED.kind, width_m = EXCLUDED.width_m, name = EXCLUDED.name,
			    geom = EXCLUDED.geom, data_version = EXCLUDED.data_version, loaded_at = now()
			""";

	private static final Set<String> ROAD_KINDS = Set.of("major", "street", "service", "path");

	public record Result(int buildings, int water, int roads) {
	}

	private final JdbcTemplate jdbc;
	private final ObjectMapper mapper;
	private final TileCacheEvictor tileCache;

	public GeoJsonImporter(JdbcTemplate jdbc, ObjectMapper mapper, TileCacheEvictor tileCache) {
		this.jdbc = jdbc;
		this.mapper = mapper;
		this.tileCache = tileCache;
	}

	/** 전부 성공하거나 전부 취소된다. 같은 파일을 다시 넣어도 결과가 같다(멱등). */
	@Transactional
	public Result importFile(Path file) throws IOException {
		JsonNode root = mapper.readTree(Files.readString(file));
		JsonNode meta = root.get("metadata");
		String version = "osm-" + meta.get("region").asString() + "-" + meta.get("fetchedOn").asString();

		List<Object[]> buildings = new ArrayList<>();
		List<Object[]> water = new ArrayList<>();
		List<Object[]> roads = new ArrayList<>();
		for (JsonNode f : root.get("features")) {
			JsonNode p = f.get("properties");
			String geometry = mapper.writeValueAsString(f.get("geometry"));
			switch (p.get("kind").asString()) {
				case "building" -> {
					double height = p.get("height_m").asDouble();
					double min = p.get("min_height_m").asDouble();
					String src = p.get("height_source").asString();
					// 잘못된 값은 넣지 않고 바로 실패시킨다(트랜잭션 전체 취소). 반쯤 들어간 지역이 생기지 않게.
					if (!(height > min && min >= 0 && height < 1000) || !HEIGHT_SOURCES.contains(src)) {
						throw new IllegalArgumentException("잘못된 건물 높이: " + p);
					}
					buildings.add(new Object[] { p.get("id").asString(), geometry, height, min, src, version });
				}
				case "water" -> water.add(new Object[] {
						p.get("id").asString(), p.path("name").isNull() ? null : p.path("name").asString(null), geometry, version });
				case "road" -> {
					String kind = p.get("road_kind").asString();
					double width = p.get("width_m").asDouble();
					if (!ROAD_KINDS.contains(kind) || !(width > 0 && width < 60)) {
						throw new IllegalArgumentException("잘못된 도로: " + p);
					}
					roads.add(new Object[] { p.get("id").asString(), kind, width,
							p.path("name").isNull() ? null : p.path("name").asString(null), geometry, version });
				}
				default -> throw new IllegalArgumentException("알 수 없는 종류: " + p.get("kind"));
			}
		}
		jdbc.batchUpdate(UPSERT_BUILDING, buildings);
		jdbc.batchUpdate(UPSERT_WATER, water);
		jdbc.batchUpdate(UPSERT_ROAD, roads);
		tileCache.evictAllAfterCommit();
		return new Result(buildings.size(), water.size(), roads.size());
	}
}
