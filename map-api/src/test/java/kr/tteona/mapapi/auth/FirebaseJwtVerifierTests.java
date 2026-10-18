package kr.tteona.mapapi.auth;

import static org.assertj.core.api.Assertions.assertThat;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.time.Instant;
import java.util.Date;
import java.util.Map;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

/** Google 대신 테스트용 RSA 키로 서명한 토큰으로, 운영과 같은 검증 규칙(validator)을 확인한다. */
class FirebaseJwtVerifierTests {

	static final String PROJECT = "tteona-test";
	static KeyPair keys;
	static KeyPair otherKeys;
	static FirebaseJwtVerifier verifier;

	@BeforeAll
	static void setUp() throws Exception {
		KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
		gen.initialize(2048);
		keys = gen.generateKeyPair();
		otherKeys = gen.generateKeyPair();
		NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey((RSAPublicKey) keys.getPublic()).build();
		decoder.setJwtValidator(FirebaseJwtVerifier.validator(PROJECT));
		verifier = new FirebaseJwtVerifier(decoder);
	}

	static String token(KeyPair signer, String iss, String aud, String sub, Instant exp, String provider) throws Exception {
		JWTClaimsSet claims = new JWTClaimsSet.Builder()
				.issuer(iss).audience(aud).subject(sub)
				.issueTime(Date.from(Instant.now().minusSeconds(10))).expirationTime(Date.from(exp))
				.claim("firebase", Map.of("sign_in_provider", provider))
				.build();
		SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.RS256), claims);
		jwt.sign(new RSASSASigner((RSAPrivateKey) signer.getPrivate()));
		return jwt.serialize();
	}

	static final String ISS = "https://securetoken.google.com/" + PROJECT;
	static final Instant LATER = Instant.now().plusSeconds(3600);

	@Test
	void 올바른_토큰이면_uid를_돌려준다() throws Exception {
		assertThat(verifier.verify(token(keys, ISS, PROJECT, "user-1", LATER, "google.com")))
				.contains(new VerifiedUser("user-1", false));
	}

	@Test
	void 익명_로그인은_게스트로_판정한다() throws Exception {
		assertThat(verifier.verify(token(keys, ISS, PROJECT, "guest-1", LATER, "anonymous")))
				.contains(new VerifiedUser("guest-1", true));
	}

	@Test
	void 다른_프로젝트_토큰은_거절한다() throws Exception {
		assertThat(verifier.verify(token(keys, "https://securetoken.google.com/other", "other", "u", LATER, "password"))).isEmpty();
		assertThat(verifier.verify(token(keys, ISS, "other", "u", LATER, "password"))).isEmpty(); // aud만 다름
	}

	@Test
	void 만료된_토큰은_거절한다() throws Exception {
		assertThat(verifier.verify(token(keys, ISS, PROJECT, "u", Instant.now().minusSeconds(3600), "password"))).isEmpty();
	}

	@Test
	void 다른_키로_서명한_위조_토큰은_거절한다() throws Exception {
		assertThat(verifier.verify(token(otherKeys, ISS, PROJECT, "u", LATER, "password"))).isEmpty();
	}

	@Test
	void 형식이_깨진_토큰은_거절한다() {
		assertThat(verifier.verify("not-a-jwt")).isEmpty();
	}
}
