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

/// URLSession redirect 차단용 delegate — HEAD 응답의 Location 헤더만 읽기 위함.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

enum UpdateChecker {

    /// GitHub repo. 배포 전 본인 repo로 교체.
    static let repoSlug = "ww-w-ai/AgentRunner"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    /// `github.com/<slug>/releases/latest` HEAD → 302 Location 헤더의 tag만 읽음.
    /// API rate limit (60/h per IP)을 회피하기 위해 web URL + HEAD 방식을 사용.
    static func check() async -> UpdateResult {
        let url = URL(string: "https://github.com/\(repoSlug)/releases/latest")!
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10

        let session = URLSession(configuration: .ephemeral,
                                 delegate: NoRedirectDelegate(),
                                 delegateQueue: nil)

        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            if http.statusCode == 404 {
                return .error("Repository or releases not found")
            }
            guard http.statusCode == 302 || http.statusCode == 301,
                  let loc = http.value(forHTTPHeaderField: "Location"),
                  let locURL = URL(string: loc) else {
                return .error("HTTP \(http.statusCode) — no redirect")
            }

            // Location 형태: https://github.com/<slug>/releases/tag/v1.0.9
            let tag = locURL.lastPathComponent  // "v1.0.9"
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let curr = current

            // DMG asset URL은 명명 규약으로 직접 구성 (build_release.sh 기준).
            let downloadStr = "https://github.com/\(repoSlug)/releases/download/\(tag)/AgentRunner-\(latest).dmg"
            let releaseStr = "https://github.com/\(repoSlug)/releases/tag/\(tag)"
            guard let downloadURL = URL(string: downloadStr),
                  let releaseURL = URL(string: releaseStr) else {
                return .error("Malformed URL construction")
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

    // 메뉴 열 때마다 자동 체크. HEAD 1회 (~100B)라 부담 없음.

    /// 설치 경로 감지 — 업데이트 가이드 분기에 사용.
    enum InstallSource {
        case homebrew    // /Applications symlink → /opt/homebrew/Caskroom/...
        case manual      // /Applications/AgentRunner.app 자체가 디렉토리
    }

    static var installSource: InstallSource {
        let bundlePath = Bundle.main.bundlePath
        // 1) Bundle path가 Caskroom 안에 직접 있는 경우 (드물게 사용자가 Caskroom의 .app 직접 실행)
        if bundlePath.contains("/Caskroom/") || bundlePath.contains("/opt/homebrew/") {
            return .homebrew
        }
        // 2) /Applications/AgentRunner.app이 심볼릭 링크인지 확인 (brew의 표준 패턴)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bundlePath),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return .homebrew
        }
        // 3) 심볼릭 링크 아니지만 resolvingSymlinks로 확인 (다른 brew prefix 등)
        let resolved = (bundlePath as NSString).resolvingSymlinksInPath
        if resolved.contains("/Caskroom/") || resolved.contains("/opt/homebrew/") {
            return .homebrew
        }
        return .manual
    }
}
