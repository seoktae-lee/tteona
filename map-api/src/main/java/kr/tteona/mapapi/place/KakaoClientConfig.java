package kr.tteona.mapapi.place;

import java.net.http.HttpClient;
import java.time.Duration;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration
class KakaoClientConfig {

	/**
	 * 타임아웃을 반드시 둔다: 연결 2초, 응답 3초.
	 * 없으면 카카오가 느려질 때 우리 요청 스레드가 전부 기다리다 서버 전체가 멈춘다(장애 전파).
	 */
	@Bean
	KakaoLocalClient kakaoLocalClient(RestClient.Builder builder,
			@Value("${mapapi.kakao.base-url}") String baseUrl,
			@Value("${mapapi.kakao.rest-key:}") String restKey) {
		var factory = new JdkClientHttpRequestFactory(
				HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build());
		factory.setReadTimeout(Duration.ofSeconds(3));
		RestClient rest = builder
				.baseUrl(baseUrl)
				.requestFactory(factory)
				.defaultHeader("Authorization", "KakaoAK " + restKey)
				.build();
		return new KakaoLocalClient(rest, !restKey.isBlank());
	}
}
