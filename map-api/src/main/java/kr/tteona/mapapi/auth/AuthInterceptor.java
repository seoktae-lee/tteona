package kr.tteona.mapapi.auth;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

/** "Authorization: Bearer <Firebase ID 토큰>"이 유효해야 통과시킨다. 검증된 사용자는 요청 속성에 담아 뒤로 넘긴다. */
@Component
public class AuthInterceptor implements HandlerInterceptor {

	public static final String USER_ATTRIBUTE = "verifiedUser";

	private final IdTokenVerifier verifier;

	public AuthInterceptor(IdTokenVerifier verifier) {
		this.verifier = verifier;
	}

	@Override
	public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
		String header = request.getHeader("Authorization");
		if (header == null || !header.startsWith("Bearer ")) {
			response.setStatus(HttpStatus.UNAUTHORIZED.value());
			return false;
		}
		return verifier.verify(header.substring(7))
				.map(user -> {
					request.setAttribute(USER_ATTRIBUTE, user);
					return true;
				})
				.orElseGet(() -> {
					response.setStatus(HttpStatus.UNAUTHORIZED.value());
					return false;
				});
	}
}
