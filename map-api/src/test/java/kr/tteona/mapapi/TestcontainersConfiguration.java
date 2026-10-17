package kr.tteona.mapapi;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfiguration {

	// 테스트마다 깨끗한 PostGIS 컨테이너를 띄운다. 로컬 compose와 같은 이미지를 써서 "내 PC에선 됐는데"를 막는다.
	// asCompatibleSubstituteFor: PostGIS 이미지를 일반 postgres 이미지 자리에 써도 된다고 Testcontainers에 알려준다.
	@Bean
	@ServiceConnection
	PostgreSQLContainer postgresContainer() {
		return new PostgreSQLContainer(
				DockerImageName.parse("imresamu/postgis:17-3.5").asCompatibleSubstituteFor("postgres"));
	}

}
