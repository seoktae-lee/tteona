package kr.tteona.mapapi;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cache.annotation.EnableCaching;

// @EnableCaching: @Cacheable이 붙은 메서드 호출을 가로채 캐시를 먼저 확인하게 한다(프록시).
@EnableCaching
@SpringBootApplication
public class MapApiApplication {

	public static void main(String[] args) {
		SpringApplication.run(MapApiApplication.class, args);
	}

}
