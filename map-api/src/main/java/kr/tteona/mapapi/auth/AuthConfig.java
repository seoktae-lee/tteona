package kr.tteona.mapapi.auth;

import java.io.IOException;
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
	 * 서비스 계정이 설정돼 있으면 Firebase로 검증하고, 없으면 모든 토큰을 거절한다(fail closed).
	 * "설정이 없으면 일단 통과"로 두면, 배포 때 설정을 빠뜨리는 순간 인증 없는 API가 열린다.
	 */
	@Bean
	IdTokenVerifier idTokenVerifier(@Value("${mapapi.firebase.service-account:}") String serviceAccount) throws IOException {
		if (serviceAccount.isBlank()) {
			log.warn("mapapi.firebase.service-account 미설정: /places 요청은 전부 401로 거절된다");
			return token -> Optional.empty();
		}
		return new FirebaseIdTokenVerifier(serviceAccount);
	}
}
