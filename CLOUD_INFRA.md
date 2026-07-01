# tteona 클라우드 인프라 레퍼런스

> KISA 2026 위치정보 클라우드 지원사업 선정 기반  
> 선정일: 2026-07-01

---

## 인스턴스 정보

| 서버 | 인스턴스명 | 스펙 | 외부 IP | 내부 IP | 패키지 |
|------|-----------|------|---------|---------|--------|
| WEB | lbs-aeron-web | 2Core/4GB/30GB | 114.110.182.45 | 10.10.10.170 | Nginx, Node.js |
| WAS | lbs-aeron-was | 8Core/16GB/50GB | 114.110.181.49 | 10.20.10.170 | Node.js, FFmpeg, PM2 |
| DB | lbs-aeron-db | 2Core/4GB/70GB | 114.110.183.183 | 10.30.10.170 | PostgreSQL 16 |

### SSH 접속

```bash
# PEM 키 권한 설정 (최초 1회)
chmod 400 ~/Downloads/에어론\ 펨키/aeron-web-key.pem
chmod 400 ~/Downloads/에어론\ 펨키/aeron-was-key.pem
chmod 400 ~/Downloads/에어론\ 펨키/aeron-db-key.pem

# WEB
ssh -i ~/Downloads/에어론\ 펨키/aeron-web-key.pem -p 30022 ubuntu@114.110.182.45

# WAS
ssh -i ~/Downloads/에어론\ 펨키/aeron-was-key.pem -p 30022 ubuntu@114.110.181.49

# DB
ssh -i ~/Downloads/에어론\ 펨키/aeron-db-key.pem -p 30022 ubuntu@114.110.183.183
```

- 접속 계정: `ubuntu`
- root 권한: `sudo -i`
- 문의: support@cloudlbs.kr

---

## 현재 아키텍처 (Before)

```
iPhone 앱
    └─ Firebase (Google 클라우드)
        ├── Firestore        ← 모든 데이터 저장
        ├── Auth             ← 이메일/Apple/Google/카카오 로그인
        ├── Cloud Functions  ← 카카오 토큰, FCM 알림, 계정삭제
        └── FCM              ← 푸시 알림

    └─ 외부 API
        ├── Google Places API  ← 장소 정보 (건당 과금)
        ├── Kakao Local Search ← 장소 검색
        └── MapKit             ← 지도

    └─ 로컬 처리
        ├── AVFoundation       ← Vlog 합성 (폰 CPU 사용)
        ├── CoreLocation       ← GPS 위치 추적
        └── FileManager        ← 영상 클립 저장
```

---

## 업그레이드 로드맵

### 단계별 계획

| 순서 | 작업 | 서버 | 예상 기간 |
|------|------|------|----------|
| 0 | SSH 접속 확인 + 서버 기본 세팅 | 전체 | 즉시 |
| 1 | tteona.kr WEB 서버 이전 + DNS 연결 | WEB | 1~2일 |
| 2 | Google Places 캐시 → PostgreSQL 이전 | DB | 2~3일 |
| 3 | 코스 공유 OG 링크 (tteona.kr/course/{id}) | WEB | 3~5일 |
| 4 | 원격 푸시 알림 APNs 직접 연동 | WAS | 3~5일 |
| 5 | 관리자 대시보드 (tteona.kr/admin) | WEB | 1~2주 |
| 6 | 서버 사이드 Vlog 생성 (FFmpeg) | WAS | 2~3주 |
| 7 | 코스 추천 엔진 | WAS+DB | 1~2주 |
| 8 | WebSocket 실시간 위치 공유 | WAS | 1~2주 |

---

## 전체 업그레이드 아이디어

### 핵심 (서버로 이전)

1. **Vlog 서버 합성** — FFmpeg로 서버에서 처리, 폰 CPU 부담 제거
2. **푸시 알림 강화** — APNs 직접 연동, 위치 기반/주간 리포트 알림 추가
3. **실시간 위치 WebSocket** — Firestore 리스너(3~5초) → 1~2초 실시간
4. **코스 추천 엔진** — 현재 위치/취향/시즌 기반 개인화 추천
5. **Google Places 캐시 DB 이전** — API 비용 80% 절감
6. **코스 공유 OG 링크** — 카카오톡 공유 시 썸네일+코스명 미리보기
7. **관리자 대시보드** — tteona.kr/admin (신고처리, 사용자관리, 통계)

### 영상/콘텐츠

8. **AI 하이라이트 자동 편집** — 흔들림 적고 밝은 클립 자동 선별
9. **BGM 자동 삽입** — 여행 태그별 분위기 음악 자동 추가
10. **멀티 포맷 Vlog 출력** — 릴스(9:16), 유튜브(16:9), 정사각형(1:1) 동시 생성

### 사용자 경험

11. **개인 여행 통계** — 총 방문 장소 수, 이동거리, Vlog 수 누적 표시
12. **코스 웹 미리보기 지도** — 브라우저에서 코스 동선 시각화 + 앱 설치 유도
13. **날씨 연동** — 장소별 현재 날씨, 날씨 기반 코스 추천
14. **코스 소요시간/거리 자동 계산** — 교통 API 연동 ("총 이동 2시간 30분")

### 그룹/소셜

15. **실시간 그룹 채팅** — WebSocket 기반, 위치 공유와 같은 화면
16. **크리에이터 랭킹** — 이번 주 인기 크리에이터, 팔로우 기능으로 확장

### 비용 절감/운영

17. **Firestore → PostgreSQL 점진적 이전** — 장기 Firebase 비용 절감
18. **서버 사이드 이미지 처리** — 썸네일 자동 생성, 압축, 저장 용량 절감
19. **콘텐츠 자동 모더레이션** — 욕설/부적절 내용 사전 필터링

### 사업 확장

20. **Android 앱 지원** — 공통 WAS API 서버로 Android 포팅 수월
21. **웹앱 (PWA)** — tteona.kr에서 앱 없이 코스 탐색 가능

---

## 법적/사업적 활용

- 서버 인프라 구축 완료 → **KISA 위치기반서비스사업자 신고** 요건 충족
- "KISA 2026 선정" → 앱스토어 설명, 랜딩페이지, 투자자 피칭에 신뢰 배지 활용
- 타 정부지원사업 지원 시 가산점

---

*작성: 2026-07-01*  
*참고: 2026클라우드지원사업_서버활용계획서.md*
