package kr.tteona.mapapi.auth;

import java.util.Optional;

/**
 * 앱이 보낸 Firebase ID 토큰을 검증한다. 유효하지 않으면 빈 값.
 * 인터페이스로 둔 이유: 운영은 Firebase로 검증하고, 테스트는 네트워크 없이 가짜 구현으로 바꿔 끼운다.
 */
public interface IdTokenVerifier {
	Optional<VerifiedUser> verify(String idToken);
}
