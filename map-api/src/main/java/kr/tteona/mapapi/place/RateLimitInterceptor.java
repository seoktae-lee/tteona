package kr.tteona.mapapi.place;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import kr.tteona.mapapi.auth.AuthInterceptor;
import kr.tteona.mapapi.auth.VerifiedUser;

/** 인증 다음에 실행된다. 검증된 uid 기준으로 세므로 IP를 바꿔도 피할 수 없다. */
@Component
public class RateLimitInterceptor implements HandlerInterceptor {

	private final PlaceRateLimiter limiter;

	public RateLimitInterceptor(PlaceRateLimiter limiter) {
		this.limiter = limiter;
	}

	@Override
	public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
		VerifiedUser user = (VerifiedUser) request.getAttribute(AuthInterceptor.USER_ATTRIBUTE);
		var retryAfter = limiter.tryAcquire(user.uid());
		if (retryAfter.isEmpty()) {
			return true;
		}
		response.setStatus(HttpStatus.TOO_MANY_REQUESTS.value());
		response.setHeader("Retry-After", String.valueOf(retryAfter.getAsLong()));
		return false;
	}
}
