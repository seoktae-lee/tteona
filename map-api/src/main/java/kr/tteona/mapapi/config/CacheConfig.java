package kr.tteona.mapapi.config;

import java.time.Duration;

import org.springframework.cache.CacheManager;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import com.github.benmanes.caffeine.cache.Caffeine;

/** 캐시마다 크기·수명이 달라서 하나의 공통 설정(spring.cache.caffeine.spec) 대신 직접 등록한다. */
@Configuration
public class CacheConfig {

	@Bean
	CacheManager cacheManager() {
		CaffeineCacheManager manager = new CaffeineCacheManager();
		// 타일: 데이터 재적재 전까지 불변. HTTP max-age와 같은 1시간, 최대 2만 장(약 100MB 이하).
		manager.registerCustomCache("tiles", Caffeine.newBuilder()
				.maximumSize(20_000).expireAfterWrite(Duration.ofHours(1)).recordStats().build());
		// 장소 검색: 가게 정보가 바뀔 수 있어 짧게 10분. 같은 검색어·근처 좌표의 반복 호출로 카카오 쿼터를 아낀다.
		manager.registerCustomCache("placeSearch", Caffeine.newBuilder()
				.maximumSize(10_000).expireAfterWrite(Duration.ofMinutes(10)).recordStats().build());
		return manager;
	}
}
