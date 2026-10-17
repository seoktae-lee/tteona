package kr.tteona.mapapi.auth;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.google.auth.oauth2.GoogleCredentials;
import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.FirebaseAuthException;
import com.google.firebase.auth.FirebaseToken;

/** Firebase Admin SDK로 ID 토큰의 서명·만료·발급 프로젝트를 검증한다. Node 서버의 verifyIdToken과 같은 역할. */
public class FirebaseIdTokenVerifier implements IdTokenVerifier {

	private static final Logger log = LoggerFactory.getLogger(FirebaseIdTokenVerifier.class);

	private final FirebaseAuth auth;

	public FirebaseIdTokenVerifier(String serviceAccountPath) throws IOException {
		try (InputStream in = new FileInputStream(serviceAccountPath)) {
			FirebaseOptions options = FirebaseOptions.builder()
					.setCredentials(GoogleCredentials.fromStream(in))
					.build();
			// 이름을 붙여 초기화한다. 기본 앱을 쓰면 같은 JVM에서 두 번 초기화할 때 예외가 난다.
			this.auth = FirebaseAuth.getInstance(FirebaseApp.initializeApp(options, "map-api"));
		}
	}

	@Override
	public Optional<VerifiedUser> verify(String idToken) {
		try {
			FirebaseToken token = auth.verifyIdToken(idToken);
			Object firebase = token.getClaims().get("firebase");
			boolean guest = firebase instanceof Map<?, ?> m && "anonymous".equals(m.get("sign_in_provider"));
			return Optional.of(new VerifiedUser(token.getUid(), guest));
		} catch (FirebaseAuthException | IllegalArgumentException e) {
			log.debug("ID 토큰 검증 실패: {}", e.getMessage()); // 토큰 원문은 로그에 남기지 않는다
			return Optional.empty();
		}
	}
}
