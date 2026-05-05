import Foundation
import CoreLocation

struct WeatherInfo {
    let description: String
    let emoji: String
    let temp: Double
}

class WeatherService {
    private let apiKey = "e8b2c4d6f0a1b3c5d7e9f2a4b6c8d0e2"

    func fetchWeather(latitude: Double, longitude: Double) async -> WeatherInfo {
        let urlString = "https://api.openweathermap.org/data/2.5/weather?lat=\(latitude)&lon=\(longitude)&appid=\(apiKey)&units=metric&lang=kr"

        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weatherArr = json["weather"] as? [[String: Any]],
              let main = json["main"] as? [String: Any],
              let id = weatherArr.first?["id"] as? Int,
              let temp = main["temp"] as? Double else {
            return WeatherInfo(description: "맑음", emoji: "☀️", temp: 20)
        }

        let (desc, emoji) = weatherEmoji(for: id)
        return WeatherInfo(description: desc, emoji: emoji, temp: temp)
    }

    private func weatherEmoji(for id: Int) -> (String, String) {
        switch id {
        case 200...232: return ("천둥번개", "⛈️")
        case 300...321: return ("이슬비", "🌦️")
        case 500...504: return ("비", "🌧️")
        case 511:       return ("진눈깨비", "🌨️")
        case 520...531: return ("소나기", "🌦️")
        case 600...622: return ("눈", "❄️")
        case 701...781: return ("안개", "🌫️")
        case 800:       return ("맑음", "☀️")
        case 801:       return ("구름 조금", "🌤️")
        case 802:       return ("구름", "⛅")
        case 803...804: return ("흐림", "☁️")
        default:        return ("맑음", "☀️")
        }
    }
}
