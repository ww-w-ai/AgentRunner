//
//  UpdateChecker.swift
//  AgentRunner
//
//  GitHub Releases API 기반 수동/자동 업데이트 체크.
//  Sparkle 의존성 없음. 새 버전 발견 시 release URL 안내.
//

import Foundation

enum UpdateResult {
    case upToDate(current: String)
    case available(latest: String, current: String, downloadURL: URL, releaseURL: URL)
    case error(String)
}

enum UpdateChecker {

    /// GitHub repo. 배포 전 본인 repo로 교체.
    static let repoSlug = "ww-w-ai/AgentRunner"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static func check() async -> UpdateResult {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            if http.statusCode == 404 {
                return .error("Repository or releases not found")
            }
            guard http.statusCode == 200 else {
                return .error("HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURLStr = json["html_url"] as? String,
                  let releaseURL = URL(string: htmlURLStr) else {
                return .error("Malformed release JSON")
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let curr = current

            // DMG asset URL 우선, 없으면 release page URL
            var downloadURL = releaseURL
            if let assets = json["assets"] as? [[String: Any]] {
                if let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                   let urlStr = dmg["browser_download_url"] as? String,
                   let u = URL(string: urlStr) {
                    downloadURL = u
                }
            }

            if compareVersions(latest, curr) > 0 {
                return .available(latest: latest, current: curr, downloadURL: downloadURL, releaseURL: releaseURL)
            } else {
                return .upToDate(current: curr)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// semver 비교. a > b → 1, a == b → 0, a < b → -1
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    // 자동 체크 인프라는 의도적으로 없음 — Preferences 창 열 때 1회만 체크.
    // 사용자에게 알림을 강요하지 않고, 본인이 설정 보러 들어왔을 때만 노출.
}
