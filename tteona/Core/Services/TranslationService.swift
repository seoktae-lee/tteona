import Foundation

/// 코스 제목 같은 UGC를 앱 언어로 번역한다. 서버(`/api/translate`)가 Google Cloud Translation을
/// 호출하고 결과를 영구 캐시하므로, 클라이언트는 화면당 한 번만 배치로 물어보면 된다.
///
/// 번역이 불가능한 상황(서버에 번역 키 미설정, 네트워크 오류)에서는
/// 언제나 원문을 그대로 돌려준다 — 번역은 부가 기능이지 표시 조건이 아니다.
actor TranslationService {
    static let shared = TranslationService()
    private let baseURL = "https://tteona.kr/api"

    /// 원문+대상언어 → 번역문. 앱 실행 동안만 유지 (영구 캐시는 서버가 담당)
    private var cache: [String: String] = [:]

    private struct Response: Decodable {
        let translations: [String]
        let translated: Bool
    }

    private func cacheKey(_ text: String, _ target: AppLanguage) -> String {
        "\(target.rawValue)|\(text)"
    }

    /// 원문이 이미 대상 언어로 쓰였는지 문자 종류로 판별한다.
    /// 한국어 유저가 한국어 코스를 보는 대다수 경우에 왕복·과금을 아끼되,
    /// 일본어·영어로 쓰인 코스는 한국어 유저에게도 번역되도록 남겨둔다.
    private func isAlreadyWritten(_ text: String, in target: AppLanguage) -> Bool {
        var hasHangul = false, hasKana = false, hasHan = false, hasLatin = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hasHangul = true
            case 0x3040...0x309F, 0x30A0...0x30FF:                  hasKana   = true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF:                  hasHan    = true
            case 0x41...0x5A, 0x61...0x7A:                          hasLatin  = true
            default: break
            }
        }
        switch target {
        case .korean:   return hasHangul
        // 가나가 없어도 한자만 있는 제목("東京旅行")은 일본어로 본다 — 한글이 섞이면 한국어.
        case .japanese: return hasKana || (hasHan && !hasHangul)
        case .english:  return hasLatin && !hasHangul && !hasKana && !hasHan
        }
    }

    /// 여러 원문을 한 번에 번역해 원문→번역문 맵을 돌려준다.
    /// 맵에 없는 원문은 호출부가 원문 그대로 표시하면 된다.
    func translate(_ texts: [String], to target: AppLanguage) async -> [String: String] {
        let wanted = Set(texts.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isAlreadyWritten($0, in: target)
        })
        guard !wanted.isEmpty else { return [:] }

        var result: [String: String] = [:]
        var missing: [String] = []
        for text in wanted {
            if let hit = cache[cacheKey(text, target)] { result[text] = hit }
            else { missing.append(text) }
        }
        guard !missing.isEmpty else { return result }

        // 서버가 요청당 50개까지만 받는다 — 넘치면 나눠 보낸다.
        for chunk in stride(from: 0, to: missing.count, by: 50).map({
            Array(missing[$0..<min($0 + 50, missing.count)])
        }) {
            guard let fetched = await fetchTranslations(chunk, to: target) else { continue }
            for (source, translated) in fetched {
                cache[cacheKey(source, target)] = translated
                result[source] = translated
            }
        }
        return result
    }

    /// 단건 편의 메서드 — 실패 시 원문을 그대로 돌려준다.
    func translate(_ text: String, to target: AppLanguage) async -> String {
        await translate([text], to: target)[text] ?? text
    }

    private func fetchTranslations(_ texts: [String], to target: AppLanguage) async -> [String: String]? {
        guard let url = URL(string: "\(baseURL)/translate") else { return nil }
        let req = await APIAuth.request(url: url, method: "POST",
                                        jsonBody: ["texts": texts, "target": target.rawValue])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // 서버에 번역 키가 없으면 원문이 그대로 온다 — 캐시에 담아 원문을 고착시키지 않는다.
            guard decoded.translated, decoded.translations.count == texts.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(texts, decoded.translations))
        } catch {
            dlog("[TranslationService] translate error:", error)
            return nil
        }
    }
}
