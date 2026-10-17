package kr.tteona.mapapi.place;

/** 외부 장소 API 실패. 종류에 따라 응답 코드를 다르게 준다(원인이 우리인지, 카카오인지, 시간 초과인지 구분). */
public class PlaceUpstreamException extends RuntimeException {

	public enum Kind {
		NOT_CONFIGURED, // 서버에 키가 없음 → 503
		QUOTA,          // 카카오 쿼터 초과 → 503 + Retry-After
		TIMEOUT,        // 응답 지연 → 504
		BAD_UPSTREAM    // 그 외 카카오 오류 → 502
	}

	private final Kind kind;

	public PlaceUpstreamException(Kind kind, String message) {
		super(message);
		this.kind = kind;
	}

	public Kind kind() {
		return kind;
	}
}
