import Foundation

enum UpdateService {
    /// Checks GitHub releases for a newer version. Returns the release URL if one exists.
    static func checkForUpdate() async -> URL? {
        guard let apiURL = URL(string: "https://api.github.com/repos/thejefflarson/ClaudeMonitor/releases/latest") else { return nil }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String,
              let htmlUrl = obj["html_url"] as? String,
              let releaseURL = URL(string: htmlUrl)
        else { return nil }

        let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return isNewer(remote, than: current) ? releaseURL : nil
    }

    private static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}
