package kr.tteona.mapapi.tile;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.ResultSet;
import java.sql.Statement;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;

import kr.tteona.mapapi.TestcontainersConfiguration;

/**
 * 성능 회귀 방지: 타일 SQL이 GiST 인덱스를 "탈 수 있는 모양"인지 검사한다.
 * 누군가 WHERE 절의 geom을 ST_Transform 등으로 감싸면 인덱스를 못 타서 이 테스트가 실패한다.
 * 테스트 데이터는 작아서 플래너가 원래 Seq Scan을 고르므로, 이 연결에서만 Seq Scan을 끄고 확인한다.
 */
@SpringBootTest
@Import(TestcontainersConfiguration.class)
class TileQueryPlanTests {

	@Autowired JdbcTemplate jdbc;

	@Test
	void 타일_쿼리는_공간_인덱스를_사용할_수_있다() {
		String plan = jdbc.execute((ConnectionCallback<String>) con -> {
			try (Statement st = con.createStatement()) {
				st.execute("SET enable_seqscan = off"); // 같은 연결에서만 적용된다
				StringBuilder sb = new StringBuilder();
				String explain = "EXPLAIN " + TileRepository.TILE_SQL.replace("?, ?, ?", "16, 55898, 25384");
				try (ResultSet rs = st.executeQuery(explain)) {
					while (rs.next()) {
						sb.append(rs.getString(1)).append('\n');
					}
				}
				st.execute("RESET enable_seqscan");
				return sb.toString();
			}
		});
		assertThat(plan).contains("buildings_geom_gist");
	}
}
