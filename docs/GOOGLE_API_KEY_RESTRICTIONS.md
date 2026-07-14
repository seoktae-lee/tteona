# Google API 키 제한 설정 가이드

> 작성 2026-07-14 · 보안감사 S6 후속 — 앱에 내장되는 키는 숨길 수 없으므로 **콘솔 제한이 유일한 방어**다.
> 작업 위치: [Google Cloud Console → API 및 서비스 → 사용자 인증 정보](https://console.cloud.google.com/apis/credentials) (프로젝트: tteona-dev)

## 떠나가 쓰는 Google 키 3개와 걸어야 할 자물쇠

| 키 | 어디에 있나 | 무엇에 쓰나 | 애플리케이션 제한 | API 제한 |
|---|---|---|---|---|
| iOS 키 | 앱 Info.plist `GOOGLE_PLACES_API_KEY` | Maps SDK 지도 + Places(New) 상세/사진 | **iOS 앱** — 번들 ID `com.seoktaedev.tteona` | Maps SDK for iOS, Places API (New) |
| Android 키 | `tteona-android/local.properties` `MAPS_API_KEY` | Maps SDK 지도 | **Android 앱** — 패키지 `com.seoktaedev.tteona` + 아래 SHA-1 두 개 | Maps SDK for Android |
| 서버 번역 키 | WAS `.env` `GOOGLE_TRANSLATE_KEY` | Cloud Translation (리뷰 번역) | **IP 주소** — `180.210.91.4`, `180.210.91.5` (서버 NAT 송신 IP 2개, 둘 다 등록) | Cloud Translation API |

Android SHA-1 (release / debug 둘 다 등록):

```
A6:03:CC:C8:38:AB:21:51:D1:61:50:7C:E9:F3:F1:A6:92:6E:C0:DE   (release)
ED:87:AA:0E:A2:12:01:19:51:E1:5C:09:69:48:D2:58:E3:7F:30:62   (debug)
```

## 설정 순서 (키마다 반복, 총 ~10분)

1. 콘솔 → 사용자 인증 정보 → 해당 API 키 클릭
2. **애플리케이션 제한사항**: 위 표에 맞게 선택 (iOS 앱 / Android 앱 / IP 주소)
   - iOS: 번들 ID 추가란에 `com.seoktaedev.tteona`
   - Android: 패키지 이름 + SHA-1 지문 항목 2개(release·debug) 추가
   - 서버: IP 두 개 모두 추가 (하나만 넣으면 NAT가 다른 IP로 나갈 때 간헐 실패)
3. **API 제한사항**: "키 제한" 선택 후 위 표의 API만 체크
4. 저장 → **반영에 최대 5분**. 저장 직후 앱에서 지도·장소상세·번역이 정상인지 확인

## 왜 안 깨지는가 (이미 확인한 것)

- iOS의 Places REST 직접 호출(PlaceDetailService·PlacesPhotoService)은 `X-Ios-Bundle-Identifier: com.seoktaedev.tteona` 헤더를 이미 보내고 있어 iOS 앱 제한과 호환된다. Maps SDK는 자동으로 번들을 증명한다.
- 서버 번역 호출은 항상 NAT 송신 IP(180.210.91.4/.5)로 나가므로 IP 제한과 호환된다.

## 확인 방법 (설정 후)

- 앱: 지도 표시, 장소 상세·사진 로드, 리뷰 번역 세 가지가 정상이면 끝
- 키 도용 차단 확인(선택): 맥 터미널에서 `curl "https://places.googleapis.com/v1/places:searchText" -H "X-Goog-Api-Key: <iOS키>" -H "Content-Type: application/json" -d '{"textQuery":"test"}'` → 제한이 걸렸다면 `REQUEST_DENIED`(API_KEY_IOS_APP_BLOCKED 류)가 떠야 정상

## 함께 알아둘 것 — Kakao REST 키

`PlaceSearchService.swift`에 Kakao Local REST 키가 내장돼 있다. Kakao는 REST 키에 앱 단위 제한 수단이 없어(플랫폼 등록은 있으나 Local API 호출을 막지는 못함) 유출 시 리스크는 "내 무료 쿼터 소진" 수준이다. 무료 API라 과금 폭탄은 없음. 쿼터 이상 소진이 보이면 카카오 개발자콘솔에서 키 재발급으로 대응.

## 모니터링

한 달에 한 번 [콘솔 → API 및 서비스 → 대시보드](https://console.cloud.google.com/apis/dashboard)에서 API별 호출량 그래프 확인 — 평소 패턴 대비 급증이 있으면 키 도용 신호. 결제 알림(예산 경보)을 월 몇만 원 수준으로 걸어두면 이중 안전장치가 된다.
