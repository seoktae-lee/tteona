package kr.tteona.mapapi.place;

import static org.mockito.ArgumentMatchers.anyDouble;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.cache.CacheManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import kr.tteona.mapapi.TestcontainersConfiguration;
import kr.tteona.mapapi.auth.IdTokenVerifier;
import kr.tteona.mapapi.auth.VerifiedUser;

@SpringBootTest
@AutoConfigureMockMvc
@Import({ TestcontainersConfiguration.class, PlaceApiTests.FakeAuth.class })
@TestPropertySource(properties = "mapapi.places.rate-limit-per-minute=5")
class PlaceApiTests {

	/** 네트워크 없이 토큰을 검증하는 가짜. "good-<uid>" 형태만 통과시킨다. */
	@TestConfiguration
	static class FakeAuth {
		@Bean
		@Primary
		IdTokenVerifier fakeVerifier() {
			return token -> token.startsWith("good-")
					? Optional.of(new VerifiedUser(token.substring(5), false))
					: Optional.empty();
		}
	}

	@Autowired MockMvc mvc;
	@Autowired CacheManager cacheManager;
	@MockitoBean KakaoLocalClient kakao; // 카카오 호출은 가짜로 바꾼다

	@BeforeEach
	void setUp() {
		cacheManager.getCache("placeSearch").clear();
		reset(kakao);
	}

	@Test
	void 토큰이_없거나_틀리면_401이고_카카오를_부르지_않는다() throws Exception {
		mvc.perform(get("/places/keyword").param("query", "성수")).andExpect(status().isUnauthorized());
		mvc.perform(get("/places/keyword").param("query", "성수").header("Authorization", "Bearer bad"))
				.andExpect(status().isUnauthorized());
		verifyNoInteractions(kakao);
	}

	@Test
	void 유효한_토큰이면_카카오_응답을_그대로_돌려준다() throws Exception {
		when(kakao.keyword("성수", 15)).thenReturn("{\"documents\":[{\"place_name\":\"대림창고\"}]}");
		mvc.perform(get("/places/keyword").param("query", "성수").header("Authorization", "Bearer good-a"))
				.andExpect(status().isOk())
				.andExpect(content().json("{\"documents\":[{\"place_name\":\"대림창고\"}]}"));
	}

	@Test
	void 같은_검색은_캐시에서_답하고_카카오는_한_번만_부른다() throws Exception {
		when(kakao.keyword("성수", 15)).thenReturn("{}");
		for (int i = 0; i < 3; i++) {
			mvc.perform(get("/places/keyword").param("query", "성수").header("Authorization", "Bearer good-b"))
					.andExpect(status().isOk());
		}
		verify(kakao, times(1)).keyword("성수", 15);
	}

	@Test
	void 근처_좌표는_반올림해서_같은_캐시를_쓴다() throws Exception {
		when(kakao.category(eq("CE7"), anyDouble(), anyDouble(), anyInt(), anyInt())).thenReturn("{}");
		// 약 1m 차이 나는 두 GPS 좌표
		mvc.perform(get("/places/category").param("code", "CE7").param("x", "127.056012").param("y", "37.544733")
				.header("Authorization", "Bearer good-c")).andExpect(status().isOk());
		mvc.perform(get("/places/category").param("code", "CE7").param("x", "127.056021").param("y", "37.544741")
				.header("Authorization", "Bearer good-c")).andExpect(status().isOk());
		verify(kakao, times(1)).category("CE7", 127.056, 37.5447, 500, 5);
	}

	@Test
	void 잘못된_입력은_400이고_카카오를_부르지_않는다() throws Exception {
		String auth = "Bearer good-d";
		mvc.perform(get("/places/keyword").param("query", " ").header("Authorization", auth)).andExpect(status().isBadRequest());
		mvc.perform(get("/places/keyword").param("query", "a").param("size", "50").header("Authorization", auth)).andExpect(status().isBadRequest());
		mvc.perform(get("/places/category").param("code", "XX1").param("x", "127").param("y", "37.5").header("Authorization", auth)).andExpect(status().isBadRequest());
		mvc.perform(get("/places/category").param("code", "CE7").param("x", "-74").param("y", "40.7").header("Authorization", auth)).andExpect(status().isBadRequest());
		verifyNoInteractions(kakao);
	}

	@Test
	void 한도를_넘으면_429와_Retry_After를_준다() throws Exception {
		when(kakao.keyword(anyString(), anyInt())).thenReturn("{}");
		for (int i = 0; i < 5; i++) {
			mvc.perform(get("/places/keyword").param("query", "q" + i).header("Authorization", "Bearer good-e"))
					.andExpect(status().isOk());
		}
		mvc.perform(get("/places/keyword").param("query", "q5").header("Authorization", "Bearer good-e"))
				.andExpect(status().isTooManyRequests())
				.andExpect(header().exists("Retry-After"));
	}

	@Test
	void 카카오_장애는_원인별로_다른_코드로_알린다() throws Exception {
		String auth = "Bearer good-f";
		when(kakao.keyword("t", 15)).thenThrow(new PlaceUpstreamException(PlaceUpstreamException.Kind.TIMEOUT, "t"));
		when(kakao.keyword("q", 15)).thenThrow(new PlaceUpstreamException(PlaceUpstreamException.Kind.QUOTA, "q"));
		when(kakao.keyword("b", 15)).thenThrow(new PlaceUpstreamException(PlaceUpstreamException.Kind.BAD_UPSTREAM, "b"));
		mvc.perform(get("/places/keyword").param("query", "t").header("Authorization", auth)).andExpect(status().isGatewayTimeout());
		mvc.perform(get("/places/keyword").param("query", "q").header("Authorization", auth))
				.andExpect(status().isServiceUnavailable()).andExpect(header().string("Retry-After", "60"));
		mvc.perform(get("/places/keyword").param("query", "b").header("Authorization", auth)).andExpect(status().isBadGateway());
	}

	@Test
	void 실패는_캐시하지_않는다() throws Exception {
		String auth = "Bearer good-g";
		when(kakao.keyword("x", 15))
				.thenThrow(new PlaceUpstreamException(PlaceUpstreamException.Kind.TIMEOUT, "t"))
				.thenReturn("{}");
		mvc.perform(get("/places/keyword").param("query", "x").header("Authorization", auth)).andExpect(status().isGatewayTimeout());
		mvc.perform(get("/places/keyword").param("query", "x").header("Authorization", auth)).andExpect(status().isOk());
	}

	@Test
	void 타일은_인증_없이_열려_있다() throws Exception {
		mvc.perform(get("/tiles/16/55523/25508.mvt")).andExpect(status().isOk());
	}
}
