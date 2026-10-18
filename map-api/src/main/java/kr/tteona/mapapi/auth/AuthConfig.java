package kr.tteona.mapapi.auth;

import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
class AuthConfig {

	private static final Logger log = LoggerFactory.getLogger(AuthConfig.class);

	/**
	 * 프로젝트 ID가 설정돼 있으면 Firebase 토큰을 검증하고, 없으면 모든 토큰을 거절한다(fail closed).
	 * "설정이 없으면 일단 통과"로 두면, 배포 때 설정을 빠뜨리는 순간 인증 없는 API가 열린다.
	 */
	@Bean
	IdTokenVerifier idTokenVerifier(@Value("${mapapi.firebase.project-id:}") String projectId) {
		if (projectId.isBlank()) {
			log.warn("mapapi.firebase.project-id 미설정: /places 요청은 전부 401로 거절된다");
			return token -> Optional.empty();
		}
		return FirebaseJwtVerifier.forProject(projectId);
	}
}
