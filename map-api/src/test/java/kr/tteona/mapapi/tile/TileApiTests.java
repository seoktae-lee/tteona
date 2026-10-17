package kr.tteona.mapapi.tile;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.file.Path;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import kr.tteona.mapapi.TestcontainersConfiguration;
import kr.tteona.mapapi.building.OsmBuildingImporter;

@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
class TileApiTests {

	static final Path SEONGSU = Path.of("data/osm-seongsu-2026-10-11.json");

	@Autowired OsmBuildingImporter importer;
	@Autowired JdbcTemplate jdbc;
	@Autowired MockMvc mvc;

	@BeforeEach
	void load() throws Exception {
		importer.importFile(SEONGSU);
	}

	@Test
	void 같은_파일을_다시_적재해도_건물_수가_늘지_않는다() throws Exception {
		importer.importFile(SEONGSU);
		Integer count = jdbc.queryForObject("SELECT count(*) FROM buildings", Integer.class);
		assertThat(count).isEqualTo(145);
	}

	@Test
	void 추정_높이와_원천_높이를_구분해서_저장한다() {
		Integer estimated = jdbc.queryForObject(
				"SELECT count(*) FROM buildings WHERE height_source = 'estimated'", Integer.class);
		assertThat(estimated).isEqualTo(123);
	}

	@Test
	void 성수_타일에는_건물이_담긴다() throws Exception {
		byte[] body = mvc.perform(get("/tiles/16/55898/25384.mvt"))
				.andExpect(status().isOk())
				.andExpect(content().contentType(TileController.MVT))
				.andReturn().getResponse().getContentAsByteArray();
		assertThat(body).isNotEmpty();
	}

	@Test
	void 건물이_없는_바다_타일은_빈_응답이다() throws Exception {
		byte[] body = mvc.perform(get("/tiles/16/55523/25508.mvt"))
				.andExpect(status().isOk())
				.andReturn().getResponse().getContentAsByteArray();
		assertThat(body).isEmpty();
	}

	@Test
	void 범위를_벗어난_타일_좌표는_400이다() throws Exception {
		mvc.perform(get("/tiles/3/8/0.mvt")).andExpect(status().isBadRequest());
		mvc.perform(get("/tiles/23/0/0.mvt")).andExpect(status().isBadRequest());
	}
}
