package kr.tteona.mapapi.tile;

import java.time.Duration;

import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/** 지도 앱(MapLibre 등)이 화면에 보이는 타일마다 호출하는 엔드포인트. */
@RestController
public class TileController {

	static final MediaType MVT = MediaType.parseMediaType("application/vnd.mapbox-vector-tile");
	private static final int MAX_ZOOM = 22;

	private final TileRepository tiles;

	public TileController(TileRepository tiles) {
		this.tiles = tiles;
	}

	@GetMapping("/tiles/{z}/{x}/{y}.mvt")
	public ResponseEntity<byte[]> tile(@PathVariable int z, @PathVariable int x, @PathVariable int y) {
		// 줌 z에서 x, y는 0 ~ 2^z-1 범위다. 범위 밖 요청은 DB까지 보내지 않고 400으로 끊는다.
		if (z < 0 || z > MAX_ZOOM || x < 0 || y < 0 || x >= (1 << z) || y >= (1 << z)) {
			return ResponseEntity.badRequest().build();
		}
		byte[] body = tiles.findBuildingsTile(z, x, y);
		// 같은 타일은 데이터를 다시 적재하기 전까지 바뀌지 않는다. 앱과 중간 캐시가 1시간 재사용하게 한다.
		// (데이터 버전이 바뀔 때의 캐시 무효화는 다음 회차 과제)
		return ResponseEntity.ok()
				.contentType(MVT)
				.cacheControl(CacheControl.maxAge(Duration.ofHours(1)).cachePublic())
				.body(body);
	}
}
