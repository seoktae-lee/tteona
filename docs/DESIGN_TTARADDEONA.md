# 따라떠나 (여행자 구독) 설계 문서

> 작성일: 2026-07-13 · 상태: **설계 단계 (미개발)**
> 대상 저장소: tteona(iOS) · tteona-android · tteona(server.js/functions)
> ⚠️ 이 문서는 **기술 뼈대(v1)**. 제품 컨셉은 [DESIGN_TTARADDEONA_CONCEPTS.md](DESIGN_TTARADDEONA_CONCEPTS.md)(v2 — 길동무·나루 엽서)가 우선한다.

---

## 1. 개요

### 1.1 문제 정의
유저 검색(프로필 탭 돋보기)으로 다른 여행자의 발자취·코스를 볼 수 있지만, 그 순간이 마지막이다.
마음에 드는 여행자를 발견해도 **다시 찾아올 이유(재방문 루프)** 가 없다.

### 1.2 목표
- 마음에 드는 여행자를 **한 번의 탭**으로 계속 따라갈 수 있게 한다.
- 그 여행자가 **새 코스를 올리면 푸시 알림**을 받는다.
- 그 여행자의 코스가 **홈 지도·탐색에서 우선 노출**된다.
- 인스타식 "팔로우/팔로워" 용어와 상호 팔로우 압박 없이, **가볍고 떠나스러운** 개념으로 만든다.

### 1.3 비목표 (하지 않는 것)
- 맞팔/승인형 관계, DM, 비공개 계정 — 소셜 그래프를 무겁게 만들지 않는다.
- 구독자 목록 공개 — 숫자만 보여주고 "누가 나를 따라오는지"는 노출하지 않는다(소셜 압박 제거).
- 피드 탭 신설 — 기존 지도/탐색 위에 얹는다. 새 탭은 만들지 않는다.

---

## 2. 컨셉·네이밍

### 2.1 이름: **"따라떠나"** (권장)
| 후보 | 장점 | 단점 |
|---|---|---|
| **따라떠나** ✅ | 브랜드(떠나)와 한 몸, 행동을 설명함, 귀여움 | 영어/일본어 번역 시 별도 워딩 필요 |
| 구독 | 누구나 이해 | 유튜브 냄새, 여행앱 감성과 이질적 |
| 같이 떠나 | 감성적 | "그룹 여행(방)" 기능과 의미 충돌 |
| 따라가기 | 직관적 | 기존 **코스 따라가기**(courseFollowed 푸시: "코스 여행을 시작했어요")와 정면 충돌 |

> ⚠️ 기존에 `course_followed`(내 코스로 여행 시작) 개념이 이미 "따라가기"를 쓰고 있다.
> **사람 구독 = 따라떠나 / 코스 실행 = 따라가기** 로 용어를 분리한다.

### 2.2 버튼 상태 & 문구 (ko/en/ja)
| 상태 | ko | en | ja |
|---|---|---|---|
| 미구독 CTA | `+ 따라떠나` | `+ Travel Along` | `+ 旅をフォロー` |
| 구독 중 | `따라가는 중 ✓` | `Traveling Along ✓` | `フォロー中 ✓` |
| 구독자 수 배지 | `N명이 따라떠나요` | `N travelers along` | `N人が旅をフォロー` |
| 새 코스 푸시 | `🧭 {닉네임}님이 새 코스를 올렸어요` / `"{코스명}" — 지금 확인해보세요` | `{nickname} posted a new course` | `{nickname}さんが新しいコースを投稿しました` |

용어 통일: 내가 따라떠나는 사람 = **"내 길동무"** (관리 화면 명칭 후보, 확정은 UI 작업 시).

---

## 3. 현재 코드베이스 분석 (설계 근거)

| 영역 | 현재 상태 | 파일 |
|---|---|---|
| 유저 검색 | 닉네임 prefix 검색, 본인·차단 제외 | `Features/Profile/UserSearchView.swift`, `FootprintService.searchUsers()` |
| 타인 프로필 | 헤더(아바타·닉네임·인증배지) + 발자취 지도 + 코스 그리드. 차단 메뉴 있음 | `Features/Profile/UserProfileView.swift` |
| 유저 모델 | `AppUser` — encode에서 admin 소유 필드(isVerified 등) 제외하는 패턴 확립 | `Core/Models/AppUser.swift` |
| 코스 업로드 | 클라이언트가 Firestore `courses` 직접 쓰기 (`CourseService.saveCourse`). 호출부는 즉석세션 저장 1곳 | `ImpromptuSessionView.swift:665` |
| 홈 지도 | `likeCount` 상위 300개 로드 + 지역검색 보완 쿼리. 필터 `enum CourseFilter { all, liked, mine }` | `CourseService.fetchCourses()`, `MainView.swift:34` |
| 추천 | WAS `/api/courses/recommend` — 인기40+신선25+거리25+태그10+시즌18 점수, 5분 캐시 | `server.js:440` |
| 푸시 2경로 | **WAS APNs**(device_tokens PG, iOS) / **Functions FCM**(userPrivate.fcmToken, fcmRequests 트리거) | `server.js:906~`, `functions/src/index.ts:203` |
| 알림 라우팅 | `type: course_liked/course_followed` → `pendingCourseId`로 코스 상세 열기 (이미 구현) | `AppNotificationManager.swift:116` |
| 좋아요 선례 | 낙관적 UI + Firestore 규칙으로 ±1만 허용하는 검증 패턴 | `CourseService.toggleLike`, `firestore.rules:41` |
| 배지 | `userPrivate.badgeCount` 누적 — WAS·Functions 공용 | `server.js bumpBadge`, functions 동일 |

**핵심 판단 3가지**
1. 코스 업로드가 서버를 거치지 않으므로, 새 코스 팬아웃 훅은 **Cloud Function `onDocumentCreated("courses/{courseId}")`** 가 유일하게 자연스러운 지점이다.
2. 팬아웃 알림은 **FCM 경로**를 쓴다 — iOS도 이미 그룹 알림을 FCM으로 받고 있고, Android와 코드가 하나로 통일된다 (WAS APNs 경로는 device_tokens가 iOS만 있던 시절의 유산).
3. 구독자 수를 유저 문서에 역정규화하면 좋아요 때처럼 규칙 검증 지옥이 된다 → **Functions 트리거가 Admin SDK로 카운터를 갱신**하면 클라이언트 규칙 문제를 원천 회피한다.

---

## 4. 데이터 모델

### 4.1 Firestore: `follows` 최상위 컬렉션 (신규)
```
follows/{followerId}_{authorId}
  followerId:    string   // 따라떠나는 사람 (나)
  authorId:      string   // 따라떠나지는 사람 (여행자)
  notifyEnabled: bool     // 새 코스 알림 수신 (기본 true, Phase 3에서 벨 토글)
  createdAt:     timestamp
```

**문서 ID를 `{followerId}_{authorId}` 복합키로 고정**하는 이유:
- 토글이 멱등 — 같은 관계 문서가 두 개 생길 수 없다.
- "내가 A를 구독 중인가?" = 문서 1건 get (쿼리 불필요).
- 규칙에서 `followId == request.auth.uid + '_' + authorId` 로 위조 차단 가능.

서브컬렉션(`users/{uid}/subscribers`) 대신 최상위를 쓰는 이유: 팬아웃(authorId 기준)과 내 구독 목록(followerId 기준) **양방향 쿼리**가 모두 필요하기 때문. 최상위 + 단일필드 인덱스 2개로 끝난다.

### 4.2 `users/{uid}` 필드 추가
```
followerCount: int   // Functions 트리거만 갱신 (클라이언트 쓰기 금지)
```
- `AppUser.encode()`에서 **제외** (isVerified와 동일한 admin-owned 패턴).
- decode는 관대하게 기본값 0.

### 4.3 `userPrivate/{uid}` 필드 추가
```
subNotifEnabled: bool   // 따라떠나 새코스 알림 전역 토글 (기본 true, groupNotifEnabled와 동일 패턴)
```

### 4.4 Firestore 인덱스
- `follows.followerId` (단일 — 자동)
- `follows.authorId` (단일 — 자동)
- 복합 인덱스 불필요 (정렬 필요 시 `authorId ASC, createdAt DESC` 추가 검토)

### 4.5 Firestore 규칙 (초안)
```
// follows 컬렉션 (따라떠나 — 여행자 구독)
match /follows/{followId} {
  // 내가 건 구독만 읽기 (구독자 목록은 비공개 — 숫자는 users.followerCount로)
  allow read: if isSignedIn() && resource.data.followerId == request.auth.uid;

  // 생성: 본인 명의 + 문서ID 복합키 일치 + 자기 자신 구독 금지
  allow create: if isSignedIn()
    && request.resource.data.followerId == request.auth.uid
    && followId == request.auth.uid + '_' + request.resource.data.authorId
    && request.resource.data.authorId != request.auth.uid;

  // 수정: 본인 구독의 notifyEnabled만
  allow update: if isSignedIn()
    && resource.data.followerId == request.auth.uid
    && request.resource.data.diff(resource.data).affectedKeys().hasOnly(['notifyEnabled']);

  allow delete: if isSignedIn() && resource.data.followerId == request.auth.uid;
}
```
그리고 `users` 규칙의 admin-owned 목록에 `followerCount` 추가:
```
.hasAny(['isVerified', 'creatorLabel', 'followerCount'])
```

> 참고: 팬아웃·카운터는 Admin SDK(규칙 우회)로 동작하므로 authorId 기준 read를 열 필요가 없다.

---

## 5. 서버 설계 (functions + server.js)

### 5.1 신규 Cloud Function ①: 새 코스 팬아웃
```
export const notifyNewCourse = onDocumentCreated("courses/{courseId}", ...)
```
흐름:
1. `follows.where(authorId == course.authorId && notifyEnabled == true)` 조회.
2. 구독자 0명이면 종료.
3. 각 구독자의 `userPrivate` 조회 → `fcmToken` 없거나 `subNotifEnabled === false`면 제외.
4. 기존 `sendGroupNotification`과 동일하게 **수신자 언어별 문구 + bumpBadge 후 1건씩 send**.
5. payload: `{ type: "new_course", courseId, authorId, courseName }`.

안전장치:
- **자기 제외**: followerId == authorId 는 규칙에서 이미 차단되지만 방어적으로 스킵.
- **차단 관계 제외**: 수신자 `users.blockedUserIds`에 authorId가 있으면 스킵.
- **도배 방지(디바운스)**: 같은 작성자의 직전 팬아웃 시각을 `userPrivate/{authorId}.lastCoursePushAt`(또는 별도 문서)에 기록, **30분 내 재업로드는 발송 생략**. 즉석세션을 연달아 저장하는 케이스가 실제로 있다.
- 팬아웃 규모: 초기 유저 규모에서 순차 send로 충분. 1,000명+ 구독자가 나오면 `sendEachForMulticast`(500개 배치)로 전환 — 코드에 TODO로 명시.

### 5.2 신규 Cloud Function ②: followerCount 카운터
```
export const onFollowWrite = onDocumentCreated + onDocumentDeleted ("follows/{followId}")
→ users/{authorId}.followerCount 를 FieldValue.increment(±1)
```
- 좋아요의 "±1 규칙 검증" 방식 대신 서버 소유로 두는 게 깔끔하다 (3.핵심판단 참조).
- 음수 방어: 감소 시 `Math.max` 불가하므로 increment 후 음수면 0으로 보정하는 read-repair를 카운터 함수에 포함.

### 5.3 server.js 변경: 추천 점수에 구독 가산점
`/api/courses/recommend` 스코어에 항목 추가:
```
// 따라떠나 가산점 (0–20점): 내가 구독한 작성자의 코스
if (followedAuthorIds.has(c.authorId)) score += 20;
```
- `followedAuthorIds`: 요청 시 `follows.where(followerId == userId)` 1회 조회 (Admin SDK).
- 캐시 키에 이미 userId가 들어 있어 **캐시 오염 없음**. 단, 구독 직후 5분 캐시 동안 반영 지연 — 허용.
- 점수 밸런스: 인기(40)보다 낮고 태그(10)보다 높게 20점 — "구독했다고 전부 상단 점령"은 막고 체감은 되는 수준. 운영하며 조정.

### 5.4 푸시 문구 (functions의 buildMessage에 추가)
```
new_course:
  ko: 🧭 {nickname}님이 새 코스를 올렸어요 / "{courseName}" — 지금 확인해보세요
  en: 🧭 {nickname} posted a new course / Check out "{courseName}"
  ja: 🧭 {nickname}さんが新しいコースを投稿しました / 「{courseName}」をチェック
```

---

## 6. 클라이언트 설계 (iOS 기준 — Android 동일 구조 이식)

### 6.1 신규 서비스: `FollowService` (`Core/Services/FollowService.swift`)
`CourseService.likedCourseIds` 패턴을 그대로 따른다.
```swift
@MainActor
final class FollowService: ObservableObject {
    @Published var followingIds: Set<String> = []      // 내가 따라떠나는 authorId들
    @Published var followerCounts: [String: Int] = [:] // 화면 캐시

    func loadMyFollowing(myUid: String) async            // 앱 시작·로그인 시 1회
    func isFollowing(_ authorId: String) -> Bool
    func toggleFollow(myUid: String, authorId: String) async throws
        // 낙관적 UI → follows/{my}_{author} setData/delete → 실패 시 롤백 (toggleLike 패턴)
    func fetchFollowerCount(authorId: String) async -> Int   // users 문서에서 followerCount 읽기
    func clear()                                          // 로그아웃 시 (FootprintService.clear 패턴)
}
```
- 환경객체로 주입 (tteonaApp에서 다른 서비스들과 동일).
- 구독 시 StatsService 이벤트 추가 검토: `.userFollowed` (user_stats 확장은 선택).

### 6.2 UserProfileView — 메인 CTA
- 헤더의 닉네임/크리에이터 라벨 아래, 발자취 요약 배지 위에 **풀폭에 가까운 캡슐 버튼**:
  - 미구독: 오렌지 채움 `+ 따라떠나` / 구독 중: 오렌지 스트로크 `따라가는 중 ✓`
  - 탭 시 `Haptics.light()` + 스프링 전환 (HapticManager 도입 흐름과 일치).
- 요약 배지 4번째로 `followerCount` 추가: `N명 · 따라떠나`.
- 차단 시(blockUser) **양방향 follows 문서 삭제**: 내 → 상대는 클라이언트가 삭제, 상대 → 나는 규칙상 클라이언트가 못 지우므로 **차단은 팬아웃 단계에서 필터** (5.1 안전장치)로 처리하고, 완전 정리는 Phase 3에서 서버 API로.

### 6.3 UserSearchView — 결과 행
- 이미 구독 중인 유저 행에 작은 `✓ 따라가는 중` 캡슐 배지 (버튼 아님 — 행 탭은 프로필 이동 유지, 오탭 방지).

### 6.4 CourseDetailView — 작성자 영역
- 작성자 닉네임 옆에 미니 `+ 따라떠나` 버튼 (코스가 마음에 든 순간이 최고의 구독 전환 지점).
- 작성자 닉네임 탭 → UserProfileView push (현재 미연결이면 함께 연결).

### 6.5 홈 지도 (MainView) — 우선 노출
1. **필터 확장**: `enum CourseFilter { all, liked, mine }` → `+ following` 케이스. 필터 칩 라벨 `따라떠나`.
2. **핀 차별화**: 구독 작성자의 코스 핀에 오렌지 링(또는 살짝 큰 스케일) — `courseMarkers` 계산 시 `followService.followingIds.contains(course.authorId)` 로 분기. GoogleMapMarker에 강조 플래그 1개 추가.
3. **로드 보완**: 인기 상위 300 쿼리에 구독 작성자의 코스가 누락될 수 있다 → `fetchCoursesInRegion` 선례처럼 **보완 쿼리** 추가:
   ```
   courses.whereField("authorId", in: chunk)  // 'in'은 30개 제한 → chunk 분할
   ```
   구독 30명 이하(대부분)면 쿼리 1번. 병합 시 courseId 중복 제거 (기존 병합 로직 재사용).

### 6.6 탐색 탭 (ExploreGridView)
- 그리드 상단에 가로 스크롤 스트립 **"내 길동무의 새 코스"** — 구독 작성자 코스 최신순 10개. 구독 0명이면 스트립 자체를 숨김 (빈 상태 UI 불필요).
- 추천 정렬은 서버 가산점(5.3)으로 자동 반영.

### 6.7 알림 수신·라우팅
- `AppNotificationManager` switch에 케이스 추가 — 기존 `course_liked` 라인에 얹기만 하면 됨:
  ```swift
  case "course_liked", "course_followed", "new_course":
      pendingCourseId = ...
  ```
- 설정 화면: 그룹 알림 토글 아래 `따라떠나 알림` 토글 (`userPrivate.subNotifEnabled`).

### 6.8 L() 키 추가 (ko/en/ja — xcstrings + strings.xml 양쪽 직접 편집)
```
follow.cta            = 따라떠나
follow.active         = 따라가는 중
follow.count          = %d명이 따라떠나요
follow.filter         = 따라떠나
follow.strip.title    = 내 길동무의 새 코스
follow.notif.setting  = 따라떠나 알림
follow.notif.desc     = 따라떠나는 여행자가 새 코스를 올리면 알려드려요
```

---

## 7. 엣지 케이스 정리

| 케이스 | 처리 |
|---|---|
| 자기 자신 구독 | 규칙 + UI(내 프로필엔 버튼 없음) + 팬아웃 방어 3중 차단 |
| A가 B를 차단 | 팬아웃에서 blockedUserIds 필터. 검색은 이미 차단 제외. 지도 필터도 blockedUserIds 필터 기존 로직 통과 |
| 구독한 유저가 계정 삭제 | `deleteMyAccount`에 follows 양방향 삭제 추가 (followerId==uid OR authorId==uid). followerCount는 카운터 함수가 자동 감소 |
| 코스 삭제 후 재업로드 도배 | 30분 디바운스 (5.1) |
| 코스 올리자마자 삭제 | 알림 탭 → 코스 없음 → 기존 pendingCourseId 흐름의 "코스를 찾을 수 없음" 처리 재사용 (동작 확인 필요) |
| 오프라인 토글 | 낙관적 UI + 실패 롤백 (toggleLike와 동일). NetworkMonitor 배너가 이미 있음 |
| 구독 수 상한 | MVP는 무제한. 남용 감지되면 규칙에 상한 불가하므로 서버 정리 배치로 대응 (기록만 해둠) |
| PRO 게이팅 | **하지 않는다** — 소셜 루프는 네트워크 효과가 생명, 유료벽 뒤에 두면 죽는다. (수익화는 MONETIZATION.md의 다른 축으로) |

---

## 8. 확장 아이디어 (Phase 3+, 이번 범위 아님)

1. **주간 다이제스트 전환**: 구독 작성자가 많아지면 즉시 알림 대신 주간 리포트 cron(월 9시)에 "이번 주 내 길동무들의 새 코스 N개" 통합.
2. **크리에이터 랭킹 연동**: `/api/creators/ranking` 점수에 followerCount 반영 → 랭킹 진입 동기 강화.
3. **구독자 마일스톤 푸시**: 작성자에게 "🎉 10명이 회원님을 따라떠나요" (10/50/100 단계).
4. **벨 토글**: 구독 유지 + 알림만 끄기 (`notifyEnabled` — 데이터 모델은 이미 준비됨).
5. **발자취 겹침 매칭**: "나와 발자취가 60% 겹치는 여행자" 추천 → 구독 유도 (visitedSigCodes 교집합).
6. **내 길동무 관리 화면**: 프로필 탭에 구독 목록 (해제·벨 관리).

---

## 9. 구현 페이즈 & 작업 목록

### Phase 1 — 코어 루프 (구독 + 새 코스 알림)
서버가 먼저, 클라이언트가 뒤 (알림 수신 코드는 이미 있어 구버전 앱도 안전):
- [ ] firestore.rules: follows 규칙 + users.followerCount 보호 → 배포
- [ ] functions: `notifyNewCourse` 팬아웃 (+디바운스, 차단 필터, ko/en/ja 문구) → 배포
- [ ] functions: `onFollowWrite` followerCount 카운터 → 배포
- [ ] iOS: FollowService + UserProfileView CTA + 요약 배지 + AppNotificationManager `new_course` 케이스
- [ ] iOS: 설정 토글 (subNotifEnabled) + L() 키 3개 언어
- [ ] Android: 동일 이식 (FollowService.kt, UserProfileScreen, FCM 핸들러 케이스)

### Phase 2 — 우선 노출
- [ ] iOS/Android: 지도 필터 `따라떠나` 칩 + 핀 강조 + authorId in 보완 쿼리
- [ ] iOS/Android: 탐색 상단 "내 길동무의 새 코스" 스트립
- [ ] server.js: 추천 점수 +20 가산점 → 배포 (※ nginx conf 덮어쓰기 사고 재발 주의 — 배포 후 WS 101 확인)
- [ ] UserSearchView/CourseDetailView 구독 진입점

### Phase 3 — 다듬기
- [ ] 계정 삭제 시 follows 정리 (deleteMyAccount 확장)
- [ ] 차단 시 양방향 완전 정리 서버 API
- [ ] 확장 아이디어(§8) 중 지표 보고 선택

### 검증 계획 (개발 시)
- 규칙: Firestore 에뮬레이터로 위조 followerId/복합키 불일치/자기구독/타인 notifyEnabled 수정 각각 거부 확인
- 팬아웃: 에뮬레이터에서 courses 문서 생성 → 구독자만 수신, 차단·알림끔·30분 디바운스 제외 확인
- E2E: 계정 2개 — A가 B 구독 → B가 즉석세션 저장 → A 기기 푸시 수신 → 탭 → 코스 상세 오픈
- 지도: 구독 작성자 코스가 인기 300 밖이어도 핀 노출 + 강조 확인

---

## 10. 리스크

| 리스크 | 심각도 | 대응 |
|---|---|---|
| 팬아웃 함수가 courses 생성마다 fires → 구독 0명이어도 follows 쿼리 1회 | 낮음 | 쿼리 1회는 저렴. 규모 커지면 authorId별 구독자 유무 캐시 |
| 알림 피로 → 구독 해제/알림 전체 꺼버림 | 중간 | 디바운스 + 전역 토글 + Phase 3 다이제스트 |
| 'in' 쿼리 30개 제한 (구독 30명 초과 시 지도 보완 쿼리 다중화) | 낮음 | chunk 분할 구현, 초기엔 도달 안 함 |
| 구버전 앱이 `new_course` 타입 미인식 | 낮음 | 알림은 뜨고 탭하면 앱만 열림 — 무해. 서버 먼저 배포해도 안전 |
| followerCount 이중 증가 (함수 재시도) | 낮음 | Functions at-least-once 특성 — eventId 멱등 처리 또는 주기적 count() 보정 배치 |
