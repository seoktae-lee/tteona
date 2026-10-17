package kr.tteona.mapapi.place;

import java.time.Clock;
import java.time.Duration;
import java.util.OptionalLong;
import java.util.concurrent.atomic.AtomicInteger;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;

/**
 * 사용자(uid)별 고정 창(fixed window) 요청 제한. 첫 요청부터 1분 동안 최대 N회.
 * 한계: 서버 메모리에 세므로 서버가 여러 대면 대수만큼 한도가 늘어난다(그때는 Redis로 옮긴다).
 */
@Component
public class PlaceRateLimiter {

	private static final Duration WINDOW = Duration.ofMinutes(1);

	private record Window(long startedAtMillis, AtomicInteger count) {
	}

	private final int limit;
	private final Clock clock;
	// 1분이 지나면 항목이 사라져 새 창이 시작된다. 오래 안 쓴 사용자 기록도 자동으로 정리된다.
	private final Cache<String, Window> windows = Caffeine.newBuilder()
			.expireAfterWrite(WINDOW).maximumSize(100_000).build();

	// 생성자가 두 개(운영용 / 테스트에서 시계를 바꿔 끼우는 용)라 Spring이 쓸 것을 명시한다.
	@Autowired
	public PlaceRateLimiter(@Value("${mapapi.places.rate-limit-per-minute}") int limit) {
		this(limit, Clock.systemUTC());
	}

	PlaceRateLimiter(int limit, Clock clock) {
		this.limit = limit;
		this.clock = clock;
	}

	/** 허용이면 빈 값, 거절이면 다시 시도할 수 있을 때까지 남은 초. */
	public OptionalLong tryAcquire(String uid) {
		Window w = windows.get(uid, k -> new Window(clock.millis(), new AtomicInteger()));
		if (w.count().incrementAndGet() <= limit) {
			return OptionalLong.empty();
		}
		long remainingMillis = WINDOW.toMillis() - (clock.millis() - w.startedAtMillis());
		return OptionalLong.of(Math.max(1, (remainingMillis + 999) / 1000));
	}
}
