---
notion: synced
agent: claude-code
---

# map-api 첫 운영 배포: 방화벽 제약 아래 배포 위치 결정

## 문제
- 카카오 장소 검색 경유 API(map-api)를 운영에 올려야 앱이 카카오 키 없이 검색할 수 있다.
- 서버는 KISA 지원 클라우드 3대(WEB 2코어/4GB nginx, WAS 8코어/16GB Node, DB 2코어/4GB PostgreSQL). 원래 계획은 WAS에 올리고 WEB nginx가 넘기는 구조였다.
- 점검 결과 WAS에는 Docker·Java가 없고, **WEB→WAS 내부 통신은 기존 Node 포트(3000)만 열려 있었다.** 새 포트는 클라우드 방화벽 정책 신청(운영사 메일)으로만 열 수 있다.

## 가설
- 방화벽 신청 없이도 운영 Node를 건드리지 않고 안전하게 배포할 방법이 있다.
- WEB 서버는 작지만(가용 2.3GB) 컨테이너 메모리 상한을 두면 nginx(사이트 전체)와 공존할 수 있다.

## 조치
- 후보 비교 후 **C(WEB 서버에 Docker로 배포)** 선택.
- 점검은 읽기 전용 명령으로만. 포트 확인은 WAS에 25초 임시 리스너(python http.server 8081)를 띄우고 WEB에서 접속 → 000(차단), 대조군 3000 → 200. 리스너 종료 확인.
- WEB 서버: Ubuntu 24.04 패키지로 Docker 29.1 + Compose 2.40 설치.
- 컨테이너: PostGIS 17-3.5 상한 384MB, map-api(Temurin 25 JRE, 비루트 사용자) 상한 640MB, `-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError`, `restart: unless-stopped`, 헬스체크.
- 노출: map-api는 `127.0.0.1:8081`에만 바인딩, PostGIS는 포트 미노출. 인터넷에는 nginx `/map-api/` 경로로만.
- 비밀: 서버 `~/map-api/.env`(권한 600). DB 비밀번호는 서버에서 `openssl rand`로 생성, 카카오 키는 SSH 표준 입력으로만 전달(명령줄·로컬 파일에 남기지 않음).
- nginx: 파일 통째 교체 대신 **현재 설정 백업(nginx가 읽지 않는 폴더) → `/api/` 블록 앞에 `/map-api/` 블록만 삽입 → `nginx -t` 실패 시 자동 복구 → reload**. 저장소 `tteona.nginx.conf`도 라이브와 동기화(기존 배포 스크립트의 덮어쓰기 검사가 뒤처진 사본을 막는다).
- 운영 전 이 Mac에서 같은 compose로 리허설(타일 200, 무토큰 401).
- 재배포 스크립트 `map-api/deploy/deploy.sh`: 테스트 → jar → 서버 이미지 빌드(커밋 해시 태그) → 교체 → 실패 시 직전 태그로 복구 → 외부 확인.

## 측정
| 확인 | 결과 |
|---|---|
| 사이트 `/` · 기존 Node `/api/health` | 200 · 200 |
| `https://tteona.kr/map-api/actuator/health` | UP |
| 타일(공개) · 범위 밖 타일 | 200(0.05s, 2,533B) · 400 |
| 장소 검색 토큰 없음 | 401 |
| 채팅 WebSocket `/ws/location` | **101** |
| actuator 다른 경로(`/map-api/actuator/env`) | 404 |
| 운영 E2E(임시 익명 계정, 확인 후 삭제) | 키워드 200(0.55s) · 반복 0.16s · 주변 200(0.12s) · 계정 USER_NOT_FOUND |
| 메모리(배포 후) | map-api 173MB/640MB · PostGIS 75MB/384MB · 서버 가용 약 1.9GB |
| 디스크 | 25% 사용(22GB 여유) |
| 배포 스크립트 | 1회차: 서버 교체 성공 후 이미지 정리 단계에서 중단(grep 무일치 exit 1 + `set -e`) → 수정 후 2회차 전 단계 통과 |

- WEB 서버 외부 송신 IP는 `180.210.91.6`, `180.210.91.7`(WAS의 .4/.5와 다름).

## 결론
- 방화벽 신청 없이, 운영 Node를 건드리지 않고 배포했다. 채팅 WebSocket 등 기존 경로는 그대로다.
- 카카오 키 허용 IP를 걸 때는 **WEB 송신 IP(.6/.7)**를 등록해야 한다(카카오 호출 주체가 WEB의 map-api).
- 컨테이너라 방화벽이 열리거나 서버를 옮길 때 같은 compose로 이전할 수 있다.

## 채택하지 않은 대안
- A. 방화벽 신청으로 WEB→WAS 8081 개방: 구조는 깔끔하지만 운영사 처리 대기가 필요하다. 나중에 옮길 수 있게 Docker로 만들었다.
- B. Node(3000)가 `/map-api`를 로컬 8081로 중계: 운영 Node 수정·재시작(채팅·위치공유 연결 순단)이 필요하고, Node 장애가 새 서비스까지 번진다.
- DB VM의 PostgreSQL에 PostGIS 설치: 운영 DB에 확장 설치와 결합이 생긴다. 지도 데이터는 분리했다.
- nginx 설정 파일 통째 교체: 과거 `/ws/` 블록 유실로 채팅이 끊긴 사고가 있었다.

## 남은 한계
- WEB은 진입점이다. map-api가 메모리 상한 안에서 죽는 것은 막았지만, CPU(2코어)는 nginx와 나눠 쓴다. 트래픽이 늘면 WAS로 옮긴다.
- 배포 중 컨테이너 교체 동안 짧은 중단이 있다(무중단 배포 아님). 앱이 아직 이 API를 쓰지 않아 지금은 영향 없음.
- 배포 스크립트의 **실패 시 복구 경로는 실제로 시험하지 않았다.**
- PostGIS 데이터 백업은 아직 없다(성수 145동은 시작 시 재적재되므로 현재는 손실 위험 낮음).
- Docker 빌드가 레거시 빌더 경고를 낸다(buildx 미설치).

## 재현
```sh
cd map-api
WEB_KEY=<web pem> deploy/deploy.sh      # 재배포
# 최초 1회: 서버에 Docker 설치, ~/map-api/.env 작성(600), nginx에 deploy/nginx-map-api.conf 블록 삽입
```
