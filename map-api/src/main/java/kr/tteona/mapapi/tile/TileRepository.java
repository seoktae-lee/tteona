package kr.tteona.mapapi.tile;

import org.springframework.cache.annotation.Cacheable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/** 타일 하나에 들어갈 건물을 골라 벡터 타일(MVT) 바이트로 만든다. 계산은 전부 PostGIS가 한다. */
@Repository
public class TileRepository {

	// 1) ST_TileEnvelope: z/x/y 타일의 영역(웹 메르카토르, EPSG:3857)
	// 2) b.geom && ...: 바운딩 박스 겹침 연산. GiST 인덱스를 타서 겹칠 가능성이 있는 건물만 빠르게 고른다.
	//    영역을 4326으로 바꿔 비교하는 이유: 인덱스가 걸린 geom 칸(4326)을 그대로 써야 인덱스가 쓰인다.
	// 3) ST_AsMVTGeom: 타일 내부 좌표(0~4096)로 변환하고 타일 밖으로 나간 부분을 잘라낸다.
	// 4) ST_AsMVT: 골라낸 행들을 'buildings' 레이어 하나로 묶어 바이너리로 만든다.
	// 테스트(TileQueryPlanTests)가 실행 계획을 검사하려고 같은 패키지에서 읽는다.
	static final String TILE_SQL = """
			WITH bounds AS (
			    SELECT ST_TileEnvelope(?, ?, ?) AS geom
			),
			features AS (
			    SELECT ST_AsMVTGeom(ST_Transform(b.geom, 3857), bounds.geom) AS geom,
			           b.height_m,
			           b.height_source
			    FROM buildings b, bounds
			    WHERE b.geom && ST_Transform(bounds.geom, 4326)
			)
			SELECT ST_AsMVT(features.*, 'buildings') FROM features
			""";

	private final JdbcTemplate jdbc;

	public TileRepository(JdbcTemplate jdbc) {
		this.jdbc = jdbc;
	}

	/**
	 * 건물이 하나도 없는 타일은 길이 0인 바이트 배열을 돌려준다.
	 * 결과는 'tiles' 캐시에 담긴다. 같은 타일을 다시 요청하면 DB까지 가지 않는다. 빈 타일도 캐시한다(없다는 사실도 반복 계산하지 않기).
	 * 데이터를 다시 적재하면 TileCacheEvictor가 커밋 뒤에 캐시를 비운다.
	 * sync = true: 캐시가 빈 타일에 동시 요청이 몰리면 한 요청만 DB로 보내고 나머지는 그 결과를 기다린다.
	 *   기본값(false)에서는 동시 요청이 각자 DB로 가서 같은 타일을 여러 번 계산했다(캐시 스탬피드, 콜드 1,518장에 1,817회).
	 */
	@Cacheable(cacheNames = "tiles", key = "#z + '/' + #x + '/' + #y", sync = true)
	public byte[] findBuildingsTile(int z, int x, int y) {
		byte[] tile = jdbc.queryForObject(TILE_SQL, byte[].class, z, x, y);
		return tile == null ? new byte[0] : tile;
	}
}
