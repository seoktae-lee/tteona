# 떠나 (Tteona) - 여행/데이트 기록 앱

> GPS 기반 위치 트리거로 각 장소에서 추억을 기록하고, 자동으로 Vlog를 생성하는 iOS 앱

[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://www.swift.org/)
[![iOS](https://img.shields.io/badge/iOS-16.0+-blue.svg)](https://www.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 📱 앱 소개

**떠나**는 여행이나 데이트를 갈 때 사용자가 따라갈 코스를 선택하고, GPS를 통해 각 장소에 도착하면 자동으로 촬영 알림을 받아 짧은 영상을 기록한 후, 하루가 끝나면 자동으로 Vlog를 생성해주는 앱입니다.

**복잡한 편집 없이**, **간단한 촬영만으로** 추억을 담은 완성도 높은 영상을 만들 수 있습니다.

---

## ✨ 주요 기능

### 1. 코스 탐색 & 공유
- 📍 지도 위에 타 유저들이 만든 여행/데이트 코스 확인
- ❤️ 좋아요 순으로 인기 있는 코스 추천
- 🎯 직접 코스를 만들어 다른 유저와 공유

### 2. GPS 기반 촬영 알림
- 📍 선택한 코스의 각 장소에 도착하면 자동 알림
- 📹 알림을 탭하면 즉시 카메라 실행
- ⏱️ 10초 제한으로 간단하게 촬영

### 3. 자동 Vlog 생성
- 🎬 촬영한 클립들을 자동으로 병합
- 🗺️ 각 장소의 지도 핀(1.5초) + 촬영 영상(10초) 조합
- 📝 장소 이름 자막 자동 오버레이
- 📱 카메라 앨범에 저장 및 SNS 공유 가능

---

## 🛠️ 기술 스택

| 항목 | 기술 |
|------|------|
| **UI** | SwiftUI |
| **지도** | MapKit |
| **위치 추적** | CoreLocation |
| **영상 촬영** | AVFoundation |
| **영상 병합** | AVMutableComposition, AVVideoComposition |
| **앨범 저장** | PHPhotoLibrary |
| **백엔드** | Firebase Firestore |
| **인증** | Firebase Auth |
| **로컬 저장** | FileManager |

---

## 🎯 MVP (Minimum Viable Product) 범위

### 포함되는 기능
✅ 코스 탐색 & 좋아요 기능  
✅ 코스 만들기 및 등록  
✅ GPS 도착 감지 및 촬영 알림  
✅ 10초 영상 촬영  
✅ 자동 Vlog 생성 (지도 + 자막 + 영상 병합)  
✅ 앨범 저장 및 ShareSheet 공유  

### 향후 업데이트 예정
🔜 커플/친구끼리 Vlog 공유 (서버 영상 저장)  
🔜 배경음악 추가  
🔜 영상 길이 선택 옵션 (5초/10초/15초)  
🔜 Android 버전  

---

## 📋 프로젝트 구조

```
tteona/
├── Core/                      # 핵심 데이터 & 비즈니스 로직
│   ├── Models/
│   ├── Services/
│   └── Extensions/
├── Features/                  # 화면별 기능
│   ├── Auth/                  # 로그인/회원가입
│   ├── Main/                  # 메인 화면 (코스 탐색)
│   ├── CourseDetail/          # 코스 상세
│   ├── CreateCourse/          # 코스 만들기
│   ├── ActiveSession/         # 데이트/여행 진행
│   ├── Camera/                # 영상 촬영
│   └── Vlog/                  # Vlog 생성 & 미리보기
└── Assets/                    # 이미지, 컬러, 폰트
```

---

## 🚀 시작하기

### 요구사항
- Xcode 15.0 이상
- iOS 16.0 이상
- Swift 5.9 이상

### 설치 및 실행

1. **리포지토리 클론**
```bash
git clone https://github.com/seoktae-lee/tteona.git
cd tteona
```

2. **Firebase 설정**
   - [Firebase Console](https://console.firebase.google.com)에서 프로젝트 생성
   - `GoogleService-Info.plist` 다운로드 후 Xcode 프로젝트에 추가
   - Firestore Database 활성화
   - Authentication (이메일/Google/Apple) 활성화

3. **Xcode에서 빌드 및 실행**
```bash
open tteona.xcodeproj
```

4. **앱 실행**
   - Xcode에서 실행 버튼(▶️) 또는 `Cmd+R`
   - 시뮬레이터 또는 실제 기기에서 테스트

---

## 📐 Firebase Firestore 구조

### courses 컬렉션
```
courses/
  {courseId}/
    ├── courseId: String
    ├── authorId: String
    ├── courseName: String
    ├── tag: String ("커플" | "친구" | "가족" | "혼자")
    ├── region: String
    ├── likeCount: Int
    ├── createdAt: Timestamp
    └── places: Array
          └── { order, placeName, latitude, longitude }
```

### likes 서브컬렉션
```
courses/{courseId}/likes/{userId}
  ├── userId: String
  └── likedAt: Timestamp
```

---

## 🎨 디자인 시스템

### 색상
- **메인**: `#FF6B35` (따뜻한 오렌지)
- **배경**: `#FFFFFF` (화이트)
- **텍스트**: `#1A1A1A` (다크 그레이)
- **서브**: `#888888` (미디움 그레이)

### 폰트
- **한글**: Apple SD Gothic Neo
- **영문**: SF Pro

---

## 🔐 보안 & 개인정보

### Firebase Security Rules
- 모든 사용자가 코스 데이터 읽기 가능
- 인증된 사용자만 코스 생성 가능
- 작성자만 자신의 코스 수정/삭제 가능
- 인증된 사용자만 좋아요 추가/제거 가능

### 데이터 처리
- 영상 클립은 **로컬에만 저장** (개인정보 보호)
- 코스 정보만 서버에 저장 (최소 비용)
- 위치 데이터는 GPS 도착 감지에만 사용

---

## 📝 개발 일지

| 날짜 | 진행 상황 |
|------|---------|
| 2026.05.05 | MVP 정의 완료, 프로젝트 초기화 |
| 2026.05.05 | 전체 기능 구현 (Auth/Map/Camera/Vlog/Firestore) |
| 진행 중... | 버그 수정 및 UI 다듬기 |

---

## 🤝 기여하기

개인 프로젝트이지만, 피드백이나 제안이 있으면 이슈(Issues)나 PR(Pull Request)로 말씀해주세요!

---

## 📄 라이선스

MIT License - [LICENSE](LICENSE) 파일 참고

---

## 👨‍💻 개발자

- **dev**: LEESEOKTAE
- **GitHub**: [@seoktae-lee](https://github.com/seoktae-lee)
- **관심 분야**: 로봇, 자율주행, 물리 AI

---

**Made with ❤️ by seoktae-lee**
