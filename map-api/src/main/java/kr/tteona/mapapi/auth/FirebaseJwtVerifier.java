package kr.tteona.mapapi.auth;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimValidator;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

/**
 * Firebase ID 토큰(JWT)을 Google 공개 키로 검증한다. 비밀 키(서비스 계정)가 필요 없다.
 * 서명은 Google이 개인 키로 하고, 우리는 공개된 키로 "Google이 서명한 게 맞는지"만 확인하면 되기 때문이다.
 *
 * 검사 항목(Firebase 공식 검증 규칙):
 *  - 서명: securetoken@system.gserviceaccount.com 공개 키(JWK)
 *  - iss = https://securetoken.google.com/{projectId}, aud = {projectId}
 *  - exp(만료)·iat 시각, sub(uid)가 비어 있지 않음
 */
public class FirebaseJwtVerifier implements IdTokenVerifier {

	static final String JWK_SET_URI =
			"https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

	private final JwtDecoder decoder;

	FirebaseJwtVerifier(JwtDecoder decoder) {
		this.decoder = decoder;
	}

	/** 운영용: Google 공개 키 목록을 내려받아(캐시) 서명을 검증한다. */
	public static FirebaseJwtVerifier forProject(String projectId) {
		NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(JWK_SET_URI).build();
		decoder.setJwtValidator(validator(projectId));
		return new FirebaseJwtVerifier(decoder);
	}

	/** 발급자·대상·만료·uid 검사. 테스트에서도 같은 규칙을 쓰도록 분리했다. */
	static OAuth2TokenValidator<Jwt> validator(String projectId) {
		return new DelegatingOAuth2TokenValidator<>(List.of(
				JwtValidators.createDefaultWithIssuer("https://securetoken.google.com/" + projectId), // 만료·iss
				new JwtClaimValidator<List<String>>("aud", aud -> aud != null && aud.contains(projectId)),
				new JwtClaimValidator<String>("sub", sub -> sub != null && !sub.isBlank())));
	}

	@Override
	public Optional<VerifiedUser> verify(String idToken) {
		try {
			Jwt jwt = decoder.decode(idToken);
			// 게스트(익명 로그인) 여부는 토큰 안의 firebase.sign_in_provider로 판정한다. 클라이언트가 주장하는 값은 믿지 않는다.
			Map<String, Object> firebase = jwt.getClaimAsMap("firebase");
			boolean guest = firebase != null && "anonymous".equals(firebase.get("sign_in_provider"));
			return Optional.of(new VerifiedUser(jwt.getSubject(), guest));
		} catch (JwtException e) {
			return Optional.empty(); // 토큰 원문·사유는 로그에 남기지 않는다
		}
	}
}
