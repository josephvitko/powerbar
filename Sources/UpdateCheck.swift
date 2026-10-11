import Foundation

/// Checks GitHub at most once a day for a newer release. Dev builds (version
/// containing "-dev") never check.
final class UpdateCheck {
    struct Release {
        let version: String
        let url: URL
    }

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private static let latestURL = URL(string: "https://api.github.com/repos/josephvitko/powerbar/releases/latest")!

    private(set) var available: Release?
    private var lastCheck = Date.distantPast
    var onChange: (() -> Void)?

    func checkIfDue() {
        guard !Self.currentVersion.contains("dev"), Date().timeIntervalSince(lastCheck) > 86400 else { return }
        lastCheck = Date()
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let page = json["html_url"] as? String,
                  let url = URL(string: page) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                self?.available = Self.isNewer(version, than: Self.currentVersion) ? Release(version: version, url: url) : nil
                self?.onChange?()
            }
        }.resume()
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
