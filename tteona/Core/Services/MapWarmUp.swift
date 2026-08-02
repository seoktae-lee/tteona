import UIKit
import GoogleMaps

/// 구글 지도를 앱이 뜨는 동안 미리 한 번 만들어 두는 예열기.
///
/// 구글 지도 SDK는 프로세스에서 **첫** GMSMapView를 만들 때 렌더러·셰이더·타일 캐시·네트워크를
/// 통째로 올린다. 이 비용이 1~3초다. 두 번째부터는 그 준비물을 재사용해 훨씬 빠르다.
///
/// 예전엔 지도가 첫 탭(tag 0)이라 이 비용이 스플래시 뒤에서 조용히 끝나 있었고,
/// 그래서 "앱 열자마자 핀이 바로" 보였다. 촬영 탭이 첫 화면이 된 뒤로는 지도가 '발견'을
/// 누른 그 순간에야 처음 만들어져, 숨어 있던 비용이 그대로 사용자 눈앞에 노출됐다.
///
/// 화면 구성은 그대로 두고 **비용을 치르는 시점만 예전으로 되돌린다** — 앱 실행 중에
/// 보이지 않는 지도를 하나 띄워 SDK를 깨워 놓고 버린다. 사용자가 발견을 누를 땐 이미 데워져 있다.
enum MapWarmUp {
    private static var started = false
    private static var probe: GMSMapView?

    static func run() {
        guard !started else { return }
        started = true

        // 창에 붙지 않으면 SDK가 렌더링을 시작하지 않아 예열이 되지 않는다
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            started = false   // 창이 아직이면 다음 기회에 다시 시도한다
            return
        }

        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: 37.5665, longitude: 126.9780, zoom: 12)
        options.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        let map = GMSMapView(options: options)
        map.isUserInteractionEnabled = false
        map.settings.setAllGesturesEnabled(false)
        map.alpha = 0.02          // 완전한 0이나 isHidden이면 렌더링을 건너뛴다
        window.insertSubview(map, at: 0)   // 맨 뒤 — 무엇도 가리지 않는다
        probe = map

        // 타일이 한 번 올라오면 목적을 다했다. 지도를 두 개 살려 둘 이유가 없으니 바로 버린다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            probe?.removeFromSuperview()
            probe = nil
        }
    }
}
