package kr.tteona.mapapi.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import kr.tteona.mapapi.auth.AuthInterceptor;
import kr.tteona.mapapi.place.RateLimitInterceptor;

/** /places/** 에만 인증 → 요청 제한 순서로 건다. 타일(/tiles)은 공개 지도 데이터라 인증 없이 둔다. */
@Configuration
class WebConfig implements WebMvcConfigurer {

	private final AuthInterceptor auth;
	private final RateLimitInterceptor rateLimit;

	WebConfig(AuthInterceptor auth, RateLimitInterceptor rateLimit) {
		this.auth = auth;
		this.rateLimit = rateLimit;
	}

	@Override
	public void addInterceptors(InterceptorRegistry registry) {
		registry.addInterceptor(auth).addPathPatterns("/places/**").order(1);
		registry.addInterceptor(rateLimit).addPathPatterns("/places/**").order(2);
	}
}
