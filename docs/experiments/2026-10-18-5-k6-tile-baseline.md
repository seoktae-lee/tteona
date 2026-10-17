---
notion: synced
agent: claude-code
---

# 지도 타일 API 부하 기준선 (캐시 없음, k6)

## 문제
- 타일 API(`GET /tiles/{z}/{x}/{y}.mvt`)는 요청마다 PostGIS가 공간 검색과 MVT 생성을 한다.
- 캐시를 붙이기 전에, 캐시 없이 어디까지 버티고 무엇이 먼저 막히는지 기준선이 필요했다. 기준선 없이 캐시를 붙이면 개선 폭을 말할 수 없다.

## 가설
- 처음 막히는 곳은 DB 커넥션 풀(기본 10개)일 것이다.
- 한계 근처에서는 평균보다 p99가 먼저 크게 늘 것이다.

## 조치
- 데이터: 성수 145동 + 합성 23.2만 동(성수 블록 40×40 격자 복제, 약 14×21km). `scripts/synthetic-grid.sql`.
- 앱은 배포와 같은 형태(`bootJar` → `java -jar`), JDK 25, Tomcat 기본 스레드 200, HikariCP 기본 풀 10.
- k6 `constant-arrival-rate`: 초당 요청 수를 고정해 서버가 느려져도 같은 속도로 보낸다(VU 고정 방식은 지연을 과소 측정한다).
- 요청: 합성 격자 안의 z16 타일을 무작위로 고름(x 55881~55913, y 25362~25407). 단계별 30초.
- 실행 중 2초 간격 표본: Hikari 대기 커넥션 수(`/actuator/metrics/hikaricp.connections.pending`), DB 컨테이너 CPU(`docker stats`), 앱 프로세스 CPU(`ps`).
- 첫 1회 50rps는 워밍업으로 제외.

## 측정
- 환경: Apple M4(10코어, 16GB), Docker 할당 10 CPU·7.6GB. k6·앱·DB가 같은 기기. PostgreSQL 17 + PostGIS 3.5(arm64 네이티브).
- CPU는 100% = 1코어.

| 목표 rps | 실제 rps | 중앙값 | p95 | p99 | 최대 | 실패 | 버린 요청 | Hikari 대기 최대 | DB CPU 최대 | 앱 CPU 최대 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 100 | 3.6ms | 4.7ms | 5.1ms | 9ms | 0 | 0 | 0 | 25% | 16% |
| 300 | 300 | 2.3ms | 2.9ms | 3.4ms | 23ms | 0 | 0 | 0 | 53% | 37% |
| 600 | 600 | 1.5ms | 1.7ms | 1.8ms | 20ms | 0 | 0 | 0 | 63% | 12% |
| 1,000 | 1,000 | 1.0ms | 1.1ms | 1.6ms | 24ms | 0 | 0 | 0 | 59% | 25% |
| 2,000 | 2,000 | 0.7ms | 0.8ms | 1.1ms | 10ms | 0 | 0 | 0 | 114% | 9% |
| 3,000 | 3,000 | 0.7ms | 0.8ms | 1.7ms | 12ms | 0 | 0 | 0 | 156% | 20% |
| 5,000 | 5,000 | 1.0ms | 1.8ms | 3.2ms | 61ms | 0 | 0 | 44 | 418% | 58% |
| 8,000 | **6,865** | **284ms** | **344ms** | 400ms | 672ms | 0 | 31,984 | 189 | **787%** | 71% |
| 12,000 | 6,788 | 293ms | 347ms | 401ms | 688ms | 0 | 154,421 | 189 | 780% | 67% |
| 100 (재측정) | 100 | 3.7ms | 4.4ms | 4.8ms | 19ms | 0 | 0 | 0 | 30% | 2% |

- 8,000rps 실행 중 k6 자체 CPU 약 63%.

## 결론
- 캐시 없는 처리 한계는 이 환경에서 **약 6,800rps**다. 그 이상은 처리량이 늘지 않고 지연만 약 300배(p95 1.8ms → 344ms) 늘었다.
- 병목은 커넥션 풀이 아니라 **DB CPU**였다(약 7.9코어 포화). 요청마다 같은 타일을 다시 계산하는 비용이다.
- Hikari 대기 189 = Tomcat 스레드 200 − 풀 10. 모든 요청 스레드가 커넥션을 기다리며 줄을 섰다. DB CPU가 이미 포화라 풀을 늘리면 경합만 커진다.
- 타일은 데이터 버전이 바뀌기 전까지 결과가 같다 → **결과 캐시가 다음 조치**. 같은 스크립트로 캐시 전후를 비교한다.
- 실패는 0이었다. 한계를 넘으면 오류 대신 대기열이 길어지는 형태로 나빠졌다.

## 채택하지 않은 대안
- 커넥션 풀 확대: 병목이 DB CPU라 효과가 없거나 역효과.
- VU 고정(closed model) 부하: 서버가 느려지면 요청도 줄어 지연이 과소 측정된다.
- 평균만 보기: 5,000rps에서 평균 1.16ms로 멀쩡해 보이지만 p99와 대기열은 이미 신호를 보냈다.

## 남은 한계
- k6·앱·DB가 한 기기에서 CPU를 나눠 쓴다. 절대값보다 병목 위치와 꺾이는 지점을 본다. 운영 서버(WAS 8코어, DB 2코어 분리)에서는 DB가 훨씬 먼저 포화될 것으로 예상하며 재측정이 필요하다.
- 합성 데이터는 같은 블록의 복제라 타일마다 비용이 비슷하다. 실제 도시는 타일별 편차가 크다.
- 저부하(100rps)에서 지연이 더 큰 현상은 순서 효과가 아니었다(마지막 재측정도 3.7ms). 요청 사이 CPU 절전 상태 진입으로 추정하며 확인하지 않았다.
- 타일 범위를 무작위로 골라 캐시 적중률이 낮은 조건이다. 실제 사용자는 같은 지역을 몰려서 보므로 캐시 효과는 더 클 수 있다.

## 재현
```sh
cd map-api
docker compose up -d --wait
docker compose exec -T postgis psql -U mapapi -d mapapi -f - < scripts/synthetic-grid.sql
./gradlew bootJar && java -jar build/libs/map-api-0.0.1-SNAPSHOT.jar --management.endpoints.web.exposure.include=health,metrics
k6 run -e RATE=50 load/tiles.js                               # 워밍업
k6 run -e RATE=5000 --summary-export=summary-5000.json load/tiles.js
curl -s localhost:8080/actuator/metrics/hikaricp.connections.pending   # 실행 중 대기열 확인
```
