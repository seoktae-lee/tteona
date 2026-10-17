package kr.tteona.mapapi.place;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.queryParam;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import java.net.SocketTimeoutException;

import org.hamcrest.Matchers;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

/** 실제 카카오를 부르지 않고 가짜 서버로 응답·오류·시간 초과를 흉내 낸다. */
class KakaoLocalClientTests {

	MockRestServiceServer kakao;
	KakaoLocalClient client;

	@BeforeEach
	void setUp() {
		RestClient.Builder builder = RestClient.builder()
				.baseUrl("https://dapi.kakao.com")
				.defaultHeader("Authorization", "KakaoAK test-key");
		kakao = MockRestServiceServer.bindTo(builder).build();
		client = new KakaoLocalClient(builder.build(), true);
	}

	@Test
	void 키워드_검색은_키를_헤더로_보내고_응답을_그대로_돌려준다() {
		kakao.expect(requestTo(Matchers.startsWith("https://dapi.kakao.com/v2/local/search/keyword.json")))
				.andExpect(queryParam("query", "%EB%8C%80%EB%A6%BC%EC%B0%BD%EA%B3%A0")) // "대림창고" URL 인코딩
				.andExpect(header("Authorization", "KakaoAK test-key"))
				.andRespond(withSuccess("{\"documents\":[]}", MediaType.APPLICATION_JSON));

		assertThat(client.keyword("대림창고", 15)).isEqualTo("{\"documents\":[]}");
		kakao.verify();
	}

	@Test
	void 카카오_429는_쿼터_초과로_구분한다() {
		kakao.expect(requestTo(Matchers.containsString("keyword.json"))).andRespond(withStatus(HttpStatus.TOO_MANY_REQUESTS));
		assertThatThrownBy(() -> client.keyword("a", 1))
				.isInstanceOfSatisfying(PlaceUpstreamException.class, e -> assertThat(e.kind()).isEqualTo(PlaceUpstreamException.Kind.QUOTA));
	}

	@Test
	void 카카오_401은_외부_오류로_구분한다() {
		kakao.expect(requestTo(Matchers.containsString("keyword.json"))).andRespond(withStatus(HttpStatus.UNAUTHORIZED));
		assertThatThrownBy(() -> client.keyword("a", 1))
				.isInstanceOfSatisfying(PlaceUpstreamException.class, e -> assertThat(e.kind()).isEqualTo(PlaceUpstreamException.Kind.BAD_UPSTREAM));
	}

	@Test
	void 응답_지연은_시간_초과로_구분한다() {
		kakao.expect(requestTo(Matchers.containsString("keyword.json"))).andRespond(withException(new SocketTimeoutException("read timed out")));
		assertThatThrownBy(() -> client.keyword("a", 1))
				.isInstanceOfSatisfying(PlaceUpstreamException.class, e -> assertThat(e.kind()).isEqualTo(PlaceUpstreamException.Kind.TIMEOUT));
	}

	@Test
	void 키가_없으면_카카오를_부르지_않고_실패한다() {
		KakaoLocalClient unconfigured = new KakaoLocalClient(RestClient.create(), false);
		assertThatThrownBy(() -> unconfigured.keyword("a", 1))
				.isInstanceOfSatisfying(PlaceUpstreamException.class, e -> assertThat(e.kind()).isEqualTo(PlaceUpstreamException.Kind.NOT_CONFIGURED));
	}
}
