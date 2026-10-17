package kr.tteona.mapapi.place;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;

class PlaceRateLimiterTests {

	@Test
	void 한도까지는_허용하고_넘으면_남은_초를_알려준다() {
		Clock fixed = Clock.fixed(Instant.parse("2026-10-18T00:00:00Z"), ZoneOffset.UTC);
		PlaceRateLimiter limiter = new PlaceRateLimiter(3, fixed);

		assertThat(limiter.tryAcquire("u1")).isEmpty();
		assertThat(limiter.tryAcquire("u1")).isEmpty();
		assertThat(limiter.tryAcquire("u1")).isEmpty();
		assertThat(limiter.tryAcquire("u1")).hasValue(60); // 4번째: 창이 막 시작됐으니 60초 뒤
	}

	@Test
	void 사용자마다_따로_센다() {
		PlaceRateLimiter limiter = new PlaceRateLimiter(1, Clock.systemUTC());
		assertThat(limiter.tryAcquire("u1")).isEmpty();
		assertThat(limiter.tryAcquire("u2")).isEmpty();
		assertThat(limiter.tryAcquire("u1")).isPresent();
	}
}
