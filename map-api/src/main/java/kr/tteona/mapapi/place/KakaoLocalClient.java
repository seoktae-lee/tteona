package kr.tteona.mapapi.place;

import java.net.SocketTimeoutException;
import java.net.http.HttpTimeoutException;

import org.springframework.web.client.HttpStatusCodeException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;

/**
 * 카카오 로컬 API 호출. 응답 JSON은 가공하지 않고 그대로 돌려준다(앱의 기존 파싱 코드를 그대로 쓰기 위해).
 * 카카오 쪽 문제는 PlaceUpstreamException으로 바꿔 던지고, 컨트롤러가 502/503/504로 구분해 응답한다.
 */
public class KakaoLocalClient {

	private final RestClient rest;
	private final boolean configured;

	public KakaoLocalClient(RestClient rest, boolean configured) {
		this.rest = rest;
		this.configured = configured;
	}

	public String keyword(String query, int size) {
		return call(() -> rest.get()
				.uri(u -> u.path("/v2/local/search/keyword.json")
						.queryParam("query", query).queryParam("size", size).build())
				.retrieve().body(String.class));
	}

	public String category(String code, double x, double y, int radius, int size) {
		return call(() -> rest.get()
				.uri(u -> u.path("/v2/local/search/category.json")
						.queryParam("category_group_code", code)
						.queryParam("x", x).queryParam("y", y)
						.queryParam("radius", radius).queryParam("size", size)
						.queryParam("sort", "distance").build())
				.retrieve().body(String.class));
	}

	private String call(java.util.function.Supplier<String> request) {
		if (!configured) {
			throw new PlaceUpstreamException(PlaceUpstreamException.Kind.NOT_CONFIGURED, "KAKAO_REST_KEY 미설정");
		}
		try {
			return request.get();
		} catch (HttpStatusCodeException e) {
			// 429 = 카카오 쿼터 초과. 그 외 4xx/5xx = 키 문제나 카카오 장애. 응답 본문은 키 정보가 섞일 수 있어 넘기지 않는다.
			var kind = e.getStatusCode().value() == 429
					? PlaceUpstreamException.Kind.QUOTA : PlaceUpstreamException.Kind.BAD_UPSTREAM;
			throw new PlaceUpstreamException(kind, "kakao status " + e.getStatusCode().value());
		} catch (ResourceAccessException e) {
			boolean timeout = e.getCause() instanceof HttpTimeoutException || e.getCause() instanceof SocketTimeoutException;
			throw new PlaceUpstreamException(
					timeout ? PlaceUpstreamException.Kind.TIMEOUT : PlaceUpstreamException.Kind.BAD_UPSTREAM, e.getMessage());
		}
	}
}
