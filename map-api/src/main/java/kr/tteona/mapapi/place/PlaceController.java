package kr.tteona.mapapi.place;

import java.util.Set;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 앱이 카카오 키를 직접 갖지 않도록 서버가 대신 카카오 로컬 검색을 호출한다.
 * 응답은 카카오 JSON 그대로다(앱의 기존 파싱 코드 재사용). 입력 검증은 카카오 호출 전에 끝낸다.
 */
@RestController
public class PlaceController {

	private static final Logger log = LoggerFactory.getLogger(PlaceController.class);

	// 카카오 카테고리 그룹 코드(음식점 FD6, 카페 CE7, 관광명소 AT4 등). 목록 밖 값은 카카오까지 보내지 않는다.
	static final Set<String> CATEGORY_CODES = Set.of("MT1", "CS2", "PS3", "SC4", "AC5", "PK6", "OL7", "SW8",
			"BK9", "CT1", "AG2", "PO3", "AT4", "AD5", "FD6", "CE7", "HP8", "PM9");

	private final PlaceSearchService places;

	public PlaceController(PlaceSearchService places) {
		this.places = places;
	}

	@GetMapping("/places/keyword")
	public ResponseEntity<String> keyword(@RequestParam String query, @RequestParam(defaultValue = "15") int size) {
		String q = query.strip();
		if (q.isEmpty() || q.length() > 100 || size < 1 || size > 15) {
			return ResponseEntity.badRequest().build();
		}
		return json(places.keyword(q, size));
	}

	@GetMapping("/places/category")
	public ResponseEntity<String> category(@RequestParam String code, @RequestParam double x, @RequestParam double y,
			@RequestParam(defaultValue = "500") int radius, @RequestParam(defaultValue = "5") int size) {
		// 카카오 로컬은 한국 좌표만 의미가 있다. 반경·개수는 카카오 허용 범위로 제한한다.
		boolean inKorea = x >= 124 && x <= 132 && y >= 33 && y <= 39.5;
		if (!CATEGORY_CODES.contains(code) || !inKorea || radius < 1 || radius > 20_000 || size < 1 || size > 15) {
			return ResponseEntity.badRequest().build();
		}
		// 소수 4자리(약 11m)로 맞춘다. GPS 값은 매번 미세하게 달라서, 그대로 키로 쓰면 캐시가 거의 맞지 않는다.
		return json(places.category(code, round4(x), round4(y), radius, size));
	}

	static double round4(double v) {
		return Math.round(v * 10_000) / 10_000.0;
	}

	private static ResponseEntity<String> json(String body) {
		return ResponseEntity.ok().contentType(MediaType.APPLICATION_JSON).body(body);
	}

	@ExceptionHandler(PlaceUpstreamException.class)
	ResponseEntity<Void> upstream(PlaceUpstreamException e) {
		log.warn("장소 검색 외부 API 실패: {} {}", e.kind(), e.getMessage());
		return switch (e.kind()) {
			case TIMEOUT -> ResponseEntity.status(HttpStatus.GATEWAY_TIMEOUT).build();
			case QUOTA -> ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).header("Retry-After", "60").build();
			case NOT_CONFIGURED -> ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
			case BAD_UPSTREAM -> ResponseEntity.status(HttpStatus.BAD_GATEWAY).build();
		};
	}
}
