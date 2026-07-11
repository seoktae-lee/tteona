import Foundation

/// 디버그 전용 로거 — 릴리스 빌드에서는 컴파일되어 아무 동작도 하지 않는다.
/// 앱 전반의 `print(...)` 진단 로그를 이걸로 대체해 배포본에 로그가 남지 않게 한다.
@inline(__always)
func dlog(_ items: Any...) {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: " "))
    #endif
}
