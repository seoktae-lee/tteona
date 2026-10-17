// 지도 타일 API 부하 테스트.
// 실행: k6 run -e RATE=300 -e BASE=http://localhost:8080 load/tiles.js
//
// arrival-rate(초당 요청 수 고정) 방식: 서버가 느려져도 요청을 계속 같은 속도로 보낸다.
// VU(가상 사용자) 고정 방식은 응답이 느려지면 다음 요청도 늦게 보내서 지연이 실제보다 작게 측정된다.
import http from 'k6/http';
import { check } from 'k6';

const RATE = Number(__ENV.RATE || 100);
const BASE = __ENV.BASE || 'http://localhost:8080';

// 합성 데이터 격자(약 14x21km)가 걸치는 z16 타일 범위. scripts/synthetic-grid.sql 참고.
const Z = 16, X_MIN = 55881, X_MAX = 55913, Y_MIN = 25362, Y_MAX = 25407;

export const options = {
	scenarios: {
		tiles: {
			executor: 'constant-arrival-rate',
			rate: RATE,
			timeUnit: '1s',
			duration: '30s',
			preAllocatedVUs: 200,
			maxVUs: 2000,
		},
	},
	// 평균은 느린 요청을 가린다. 사용자 체감에 가까운 p95, p99를 본다.
	summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
	thresholds: {
		http_req_failed: ['rate<0.01'],
	},
};

const pick = (min, max) => min + Math.floor(Math.random() * (max - min + 1));

export default function () {
	const res = http.get(`${BASE}/tiles/${Z}/${pick(X_MIN, X_MAX)}/${pick(Y_MIN, Y_MAX)}.mvt`, {
		tags: { name: 'tile' }, // URL마다 따로 집계되지 않게 하나로 묶는다
	});
	check(res, { 'status 200': (r) => r.status === 200 });
}
