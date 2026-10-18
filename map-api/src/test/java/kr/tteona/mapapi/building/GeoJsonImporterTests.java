package kr.tteona.mapapi.building;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import kr.tteona.mapapi.TestcontainersConfiguration;

/** 표준 GeoJSON 적재: 건물 조각(공중 시작)·물·멱등·잘못된 값 거부, 그리고 타일에 두 레이어가 담기는지. */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
class GeoJsonImporterTests {

	static final Path FIXTURE = Path.of("src/test/resources/osm-testtown-2026-10-18.geojson");

	@Autowired GeoJsonImporter importer;
	@Autowired JdbcTemplate jdbc;
	@Autowired MockMvc mvc;

	// 테스트 클래스들이 같은 DB 컨테이너를 공유한다. 넣은 데이터를 앞뒤로 지워 다른 테스트(성수 145동 개수 검사)에 섞이지 않게 한다.
	@BeforeEach
	@AfterEach
	void clean() {
		jdbc.update("DELETE FROM buildings WHERE data_version LIKE 'osm-testtown%'");
		jdbc.update("DELETE FROM water_areas");
		jdbc.update("DELETE FROM roads");
	}

	@Test
	void 건물_조각과_물을_적재하고_다시_넣어도_늘지_않는다() throws Exception {
		assertThat(importer.importFile(FIXTURE)).isEqualTo(new GeoJsonImporter.Result(2, 1, 1));
		importer.importFile(FIXTURE);
		assertThat(jdbc.queryForObject("SELECT count(*) FROM buildings WHERE data_version = 'osm-testtown-2026-10-18'", Integer.class)).isEqualTo(2);
		assertThat(jdbc.queryForObject("SELECT count(*) FROM water_areas", Integer.class)).isEqualTo(1);
		// 공중에서 시작하는 조각(롯데월드타워 상층부 같은)의 시작 높이가 보존된다
		assertThat(jdbc.queryForObject("SELECT min_height_m FROM buildings WHERE source_id = '900002'", Double.class)).isEqualTo(520.0);
		// 호수 안의 섬(inner ring)도 구멍으로 보존된다
		assertThat(jdbc.queryForObject("SELECT ST_NumInteriorRings(ST_GeometryN(geom, 1)) FROM water_areas", Integer.class)).isEqualTo(1);
	}

	@Test
	void 잘못된_높이가_하나라도_있으면_아무것도_적재하지_않는다() throws Exception {
		String broken = Files.readString(FIXTURE).replace("\"height_m\":560,\"min_height_m\":520", "\"height_m\":500,\"min_height_m\":520");
		Path file = Files.createTempFile("broken", ".geojson");
		Files.writeString(file, broken);
		assertThatThrownBy(() -> importer.importFile(file)).isInstanceOf(IllegalArgumentException.class);
		assertThat(jdbc.queryForObject("SELECT count(*) FROM buildings WHERE data_version LIKE 'osm-testtown%'", Integer.class)).isZero();
		assertThat(jdbc.queryForObject("SELECT count(*) FROM water_areas", Integer.class)).isZero();
	}

	@Test
	void 타일에_건물과_물_레이어가_함께_담긴다() throws Exception {
		importer.importFile(FIXTURE);
		String tower = tile("/tiles/16/55906/25391.mvt");
		assertThat(tower).contains("buildings").contains("min_height_m").contains("900002");
		String lake = tile("/tiles/16/55906/25392.mvt");
		assertThat(lake).contains("water");
		assertThat(tower).contains("roads").contains("width_m").contains("major");
	}

	@Test
	void 물이_없는_타일에서도_건물이_사라지지_않는다() throws Exception {
		importer.importFile(FIXTURE);
		// 건물만 있고 물은 없는 타일: 물 레이어가 비어도 이어 붙인 결과가 NULL이 되면 안 된다
		jdbc.update("DELETE FROM water_areas");
		assertThat(tile("/tiles/16/55906/25391.mvt")).contains("buildings");
	}

	private String tile(String path) throws Exception {
		byte[] body = mvc.perform(get(path)).andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray();
		return new String(body, StandardCharsets.ISO_8859_1);
	}
}
