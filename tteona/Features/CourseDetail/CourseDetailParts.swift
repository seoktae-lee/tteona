import SwiftUI
import MapKit
import CoreLocation

// 코스 상세 화면의 공용 조각.
//
// 같은 코스인데 **어디로 들어갔느냐에 따라 다른 정보가 보이는** 문제가 있었다.
// 탐색 탭은 ExploreDetailView(날씨·교통), 지도 탭은 CourseDetailView(근처 맛집·출처 표기)를
// 열어서, 화면마다 있는 것과 없는 것이 갈렸다. 두 화면을 하나로 합치는 대신
// 조각을 여기로 모아 양쪽이 같은 것을 쓰게 한다.
//
// (특히 출처 표기는 이용약관 11조에 명시한 의무라 어느 경로로 열어도 보여야 한다)

// MARK: - 코스 요약 한 줄

/// 사진 바로 아래에서 "갈 만한가"를 즉시 판단하게 해주는 한 줄.
///
/// 코스를 볼 때 사람이 던지는 질문은 셋이다 — 뭐 하는 코스인가, 얼마나 걸리나,
/// 나한테서 얼마나 먼가. 예전에는 이동 정보가 화면 맨 아래에 있었고 **나와의 거리는
/// 아예 없어서**(지도 미리보기 카드에만 있었다) 스크롤을 끝까지 내려야 판단이 됐다.
///
/// 여기서는 좌표만으로 즉시 구할 수 있는 것만 보여준다. 교통수단별 실측 소요시간은
/// 아래 CourseTravelInfo가 따로 조회한다 — 요약 한 줄이 네트워크를 기다리면 안 된다.
struct CourseSummaryBar: View {
    let course: Course

    @State private var fromMeKm: Double?

    var body: some View {
        HStack(spacing: 6) {
            item(String(format: L("coursedetail.summaryPlaces"), course.displayPlaces.count))
            if course.totalDistanceKm > 0 {
                dot
                item(String(format: L("coursedetail.summaryMove"),
                            Self.format(course.totalDistanceKm)))
            }
            if let fromMeKm {
                dot
                item(String(format: L("coursedetail.summaryFromMe"), Self.format(fromMeKm)))
            }
            Spacer(minLength: 0)
        }
        .task { fromMeKm = Self.distanceFromMe(to: course) }
    }

    private var dot: some View {
        Text("·").font(.tte(12)).foregroundColor(.tteMediumGray.opacity(0.6))
    }

    private func item(_ text: String) -> some View {
        Text(text).font(.tte(12, .medium)).foregroundColor(.tteMediumGray)
    }

    /// 1km 미만은 m로 — "0.4km"보다 "400m"가 걸어갈 거리인지 바로 읽힌다
    static func format(_ km: Double) -> String {
        km < 1 ? "\(Int((km * 1000).rounded() / 10) * 10)m" : String(format: "%.1fkm", km)
    }

    /// 마지막으로 알려진 위치만 읽는다. 상세 화면이 위치 추적을 새로 시작하면
    /// 배터리를 쓰고 권한 흐름도 복잡해진다 — 권한이 이미 있을 때만 값이 나온다.
    private static func distanceFromMe(to course: Course) -> Double? {
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways,
              let me = manager.location,
              let main = course.mainPlace else { return nil }
        return me.distance(from: CLLocation(latitude: main.latitude,
                                            longitude: main.longitude)) / 1000
    }
}

// MARK: - 공공데이터 출처 표기

/// 큐레이션 코스의 정보 제공처. **이용조건상 의무**이므로 지우지 말 것.
struct CourseSourceLabel: View {
    let course: Course

    var body: some View {
        if let source = course.localizedCurationSource {
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.tte(10))
                Text("\(L("coursedetail.sourceLabel")) · \(source)")
                    .font(.tte(11))
                Spacer()
            }
            .foregroundColor(.tteDarkGray.opacity(0.6))
        }
    }
}

// MARK: - 날씨 + 이동 정보

/// 대표 장소의 현재 날씨와 교통수단별 소요시간·거리.
///
/// 상태와 조회를 이 뷰가 직접 들고 있다. 부모가 @State 네 개와 로딩 플래그 둘을
/// 떠안으면 화면마다 같은 코드를 복사하게 되고, 실제로 그래서 한쪽에만 있었다.
struct CourseTravelInfo: View {
    let course: Course

    @State private var weather: WeatherInfo?
    @State private var carRoute: RouteInfo?
    @State private var walkRoute: RouteInfo?
    @State private var transitRoute: RouteInfo?
    @State private var isLoadingRoute = true
    @State private var isLoadingTransit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            weatherCard
            transportSection
        }
        .task {
            if let main = course.mainPlace {
                weather = await ExploreInfoService.shared.fetchWeather(
                    lat: main.latitude, lng: main.longitude)
            }
            // 자동차: 서버 실측(한국=카카오모빌리티) 우선, 실패 시 로컬 추정 폴백
            if let serverCar = await ExploreInfoService.shared.computeServerRoute(
                places: course.places, mode: "car") {
                carRoute = serverCar
            } else {
                carRoute = await ExploreInfoService.shared.computeRoute(
                    places: course.places, transport: .automobile)
            }
            walkRoute = await ExploreInfoService.shared.computeRoute(
                places: course.places, transport: .walking)
            isLoadingRoute = false
            transitRoute = await ExploreInfoService.shared.computeTransitRoute(places: course.places)
            isLoadingTransit = false
        }
    }

    private var weatherCard: some View {
        HStack(spacing: 10) {
            Text(weather?.emoji ?? "🌡️").font(.tte(22))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("detail.currentWeather"))
                    .font(.tte(12, .semibold))
                    .foregroundColor(.tteMediumGray)
                Text(weather.map { "\(Int($0.tempC))° \($0.description)" } ?? "-")
                    .font(.tte(15, .bold))
                    .foregroundColor(.tteDarkGray)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("detail.transport"))
                .font(.tte(16, .bold))
                .foregroundColor(.tteDarkGray)

            VStack(spacing: 0) {
                transportRow(icon: "car.fill", label: L("detail.transport.car"),
                             route: carRoute, loading: isLoadingRoute)
                Divider().padding(.leading, 44)
                transportRow(icon: "bus.fill", label: L("detail.transport.transit"),
                             route: transitRoute, loading: isLoadingTransit,
                             unavailableText: L("detail.noInfo"))
                Divider().padding(.leading, 44)
                transportRow(icon: "figure.walk", label: L("detail.transport.walk"),
                             route: walkRoute, loading: isLoadingRoute)
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemBackground)))
        }
    }

    private func transportRow(icon: String, label: String, route: RouteInfo?,
                              loading: Bool, unavailableText: String = "-") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.tte(15))
                .foregroundColor(.tteOrange)
                .frame(width: 24)
            Text(label)
                .font(.tte(15, .medium))
                .foregroundColor(.tteDarkGray)
            Spacer()
            if loading {
                ProgressView().scaleEffect(0.8)
            } else if let route {
                Text("\(route.timeText) · \(route.distanceText)")
                    .font(.tte(15, .semibold))
                    .foregroundColor(.tteDarkGray)
            } else {
                Text(unavailableText)
                    .font(.tte(14))
                    .foregroundColor(.tteMediumGray)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - 근처 추천 식당

/// 코스 근처의 추천 식당.
///
/// 코스의 places에 끼워 넣지 않고 곁들임으로만 보여준다 — 이용약관 11조에
/// "원 데이터를 임의로 수정하지 않는다"고 명시했고 장소 추가는 그 범위를 넘는다.
/// 그래서 번호를 매기지 않고 안내 문구를 함께 둔다.
struct CourseNearbyFoodSection: View {
    let course: Course
    var onSelect: (NearbyFood) -> Void

    var body: some View {
        if let foods = course.nearbyFood, !foods.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "fork.knife")
                        .font(.tte(12))
                    Text(L("coursedetail.nearbyFood"))
                        .font(.tte(14, .semibold))
                }
                .foregroundColor(.tteDarkGray)

                Text(L("coursedetail.nearbyFoodHint"))
                    .font(.tte(11))
                    .foregroundColor(.tteDarkGray.opacity(0.55))
                    .padding(.top, 3)
                    .padding(.bottom, 10)

                VStack(spacing: 8) {
                    ForEach(foods) { food in
                        row(food)
                    }
                }
            }
        }
    }

    private func row(_ food: NearbyFood) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(food.name)
                        .font(.tte(13, .medium))
                        .foregroundColor(.tteDarkGray)
                        .lineLimit(1)
                    // 방송 출처가 붙는 단계에서 뱃지가 여기 표시된다
                    if let source = food.source {
                        Text(source)
                            .font(.tte(10, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.tteOrange))
                    }
                }
                HStack(spacing: 6) {
                    if let rating = food.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.tte(9))
                                .foregroundColor(.tteOrange)
                            Text(String(format: "%.1f", rating))
                                .font(.tte(11, .medium))
                                .foregroundColor(.tteDarkGray.opacity(0.8))
                        }
                    }
                    Text(String(format: L("coursedetail.nearbyFoodDistance"),
                                food.nearPlaceName, food.distanceM))
                        .font(.tte(11))
                        .foregroundColor(.tteDarkGray.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.tte(11))
                .foregroundColor(.tteDarkGray.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.tteDarkGray.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            onSelect(food)
        }
    }
}
