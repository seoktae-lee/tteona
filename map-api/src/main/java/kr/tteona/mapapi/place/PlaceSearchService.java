package kr.tteona.mapapi.place;

import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

/**
 * 카카오 호출 결과를 10분 캐시한다(CacheConfig의 placeSearch).
 * 좌표 반올림은 이 클래스 밖(컨트롤러)에서 한다. 같은 클래스 안에서 자기 @Cacheable 메서드를 부르면
 * 프록시를 거치지 않아 캐시가 동작하지 않기 때문이다(self-invocation).
 * 실패(예외)는 캐시하지 않는다. 카카오가 잠깐 장애였다고 10분 동안 실패를 돌려주면 안 된다.
 */
@Service
public class PlaceSearchService {

	private final KakaoLocalClient kakao;

	public PlaceSearchService(KakaoLocalClient kakao) {
		this.kakao = kakao;
	}

	@Cacheable(cacheNames = "placeSearch", key = "'kw:' + #size + ':' + #query")
	public String keyword(String query, int size) {
		return kakao.keyword(query, size);
	}

	@Cacheable(cacheNames = "placeSearch", key = "'cat:' + #code + ':' + #x + ',' + #y + ':' + #radius + ':' + #size")
	public String category(String code, double x, double y, int radius, int size) {
		return kakao.category(code, x, y, radius, size);
	}
}
