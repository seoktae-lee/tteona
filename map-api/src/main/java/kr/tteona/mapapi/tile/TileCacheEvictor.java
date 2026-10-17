package kr.tteona.mapapi.tile;

import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 데이터 적재 후 타일 캐시를 비운다.
 * 반드시 트랜잭션이 "커밋된 뒤"에 비운다. 커밋 전에 비우면, 그 틈에 들어온 요청이
 * 아직 커밋 전(=옛) 데이터로 타일을 만들어 캐시에 다시 넣는 경쟁 조건이 생긴다.
 */
@Component
public class TileCacheEvictor {

	private final CacheManager cacheManager;

	public TileCacheEvictor(CacheManager cacheManager) {
		this.cacheManager = cacheManager;
	}

	public void evictAllAfterCommit() {
		if (TransactionSynchronizationManager.isSynchronizationActive()) {
			TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
				@Override
				public void afterCommit() {
					evictAll();
				}
			});
		} else {
			evictAll(); // 트랜잭션 밖에서 불리면 바로 비운다
		}
	}

	private void evictAll() {
		Cache tiles = cacheManager.getCache("tiles");
		if (tiles != null) {
			tiles.clear();
		}
	}
}
