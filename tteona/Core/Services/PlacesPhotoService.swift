import Foundation

actor PlacesPhotoService {
    static let shared = PlacesPhotoService()
    private init() {}

    private var cache: [String: String] = [:]

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    func photoURL(for placeName: String) async -> String? {
        if let cached = cache[placeName] { return cached }

        guard !apiKey.isEmpty,
              let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("places.photos", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["textQuery": placeName])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]],
              let photos = places.first?["photos"] as? [[String: Any]],
              let photoName = photos.first?["name"] as? String
        else { return nil }

        let mediaStr = "https://places.googleapis.com/v1/\(photoName)/media?maxHeightPx=800&skipHttpRedirect=true&key=\(apiKey)"
        guard let mediaURL = URL(string: mediaStr),
              let (mediaData, _) = try? await URLSession.shared.data(from: mediaURL),
              let mediaJson = try? JSONSerialization.jsonObject(with: mediaData) as? [String: Any],
              let photoUri = mediaJson["photoUri"] as? String
        else { return nil }

        cache[placeName] = photoUri
        return photoUri
    }
}
