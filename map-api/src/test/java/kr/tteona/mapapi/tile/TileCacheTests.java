package kr.tteona.mapapi.tile;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Path;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionTemplate;

import kr.tteona.mapapi.TestcontainersConfiguration;
import kr.tteona.mapapi.building.OsmBuildingImporter;

@SpringBootTest
@Import(TestcontainersConfiguration.class)
class TileCacheTests {

	static final Path SEONGSU = Path.of("data/osm-seongsu-2026-10-11.json");
	static final String KEY = "16/55898/25384";

	@Autowired TileRepository tiles;
	@Autowired OsmBuildingImporter importer;
	@Autowired TileCacheEvictor evictor;
	@Autowired CacheManager cacheManager;
	@Autowired JdbcTemplate jdbc;
	@Autowired TransactionTemplate tx;

	Cache cache;

	@BeforeEach
	void setUp() throws Exception {
		importer.importFile(SEONGSU); // 데이터 복구 + 캐시 비우기
		cache = cacheManager.getCache("tiles");
	}

	@Test
	void 같은_타일은_두번째부터_DB를_거치지_않는다() throws Exception {
		byte[] first = tiles.findBuildingsTile(16, 55898, 25384);
		jdbc.update("DELETE FROM buildings"); // DB를 비워도
		byte[] second = tiles.findBuildingsTile(16, 55898, 25384);
		assertThat(second).isNotEmpty().isEqualTo(first); // 캐시에서 나오므로 그대로다
	}

	@Test
	void 다시_적재하면_커밋_뒤에_캐시가_비워진다() throws Exception {
		tiles.findBuildingsTile(16, 55898, 25384);
		assertThat(cache.get(KEY)).isNotNull();

		importer.importFile(SEONGSU);

		assertThat(cache.get(KEY)).isNull();
	}

	@Test
	void 트랜잭션이_롤백되면_캐시를_비우지_않는다() {
		tiles.findBuildingsTile(16, 55898, 25384);

		tx.executeWithoutResult(status -> {
			evictor.evictAllAfterCommit(); // 비우기를 예약했지만
			status.setRollbackOnly();      // 커밋되지 않으면
		});

		assertThat(cache.get(KEY)).isNotNull(); // 캐시는 그대로 남는다
	}
}
