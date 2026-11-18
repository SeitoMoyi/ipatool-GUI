import Foundation

/// Signed-out searches use Apple's public catalogs. The installed CLI handles account operations.
struct StoreCatalog {
    var session = URLSession.shared

    func search(term: String, country: String, platform: StorePlatform) async throws -> [StoreApp] {
        if platform == .visionos {
            return try await searchVision(term: term, country: country)
        }

        let entity: String
        switch platform {
        case .iphone: entity = "software"
        case .ipad: entity = "iPadSoftware"
        case .appletv: entity = "software,tvSoftware"
        case .watchos: entity = "software,watchSoftware"
        case .visionos: entity = "xrosSoftware"
        case .macos: entity = "macSoftware"
        }
        let results = try await catalog("/search", query: [
            "term": term, "country": country, "media": "software", "entity": entity, "limit": "50"
        ])
        var seen = Set<Int64>()
        return results.filter {
            platform != .watchos || ($0.supportedDevices ?? []).contains(where: { $0.hasPrefix("Watch") })
        }.map(\.app).filter { $0.id > 0 && seen.insert($0.id).inserted }
    }

    private func catalog(_ path: String, query: [String: String]) async throws -> [CatalogApp] {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "itunes.apple.com"
        address.path = path
        address.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, _) = try await fetch(address.url!)
        return try JSONDecoder().decode(CatalogResponse.self, from: data).results
    }

    private func searchVision(term: String, country: String) async throws -> [StoreApp] {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "apps.apple.com"
        address.path = "/\(country.lowercased())/vision/search"
        address.queryItems = [URLQueryItem(name: "term", value: term)]
        address.percentEncodedQuery = address.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, destination) = try await fetch(address.url!)
        guard destination?.host() == address.host, destination?.path == address.path else {
            throw IPATool.CommandError("Apple redirected the Vision Pro search away from the selected storefront.")
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let marker = html.range(of: "id=\"serialized-server-data\"") ?? html.range(of: "id='serialized-server-data'"),
              let opening = html[marker.upperBound...].firstIndex(of: ">"),
              let closing = html[opening...].range(of: "</script>") else {
            throw IPATool.CommandError("Apple’s Vision Pro search response was unreadable.")
        }
        let json = Data(html[html.index(after: opening)..<closing.lowerBound].utf8)
        let page = try JSONDecoder().decode(VisionPage.self, from: json)
        var seen = Set<Int64>()
        let matches = page.data.flatMap { $0.data.shelves ?? [] }.flatMap { $0.items ?? [] }.compactMap { item -> StoreApp? in
            guard item.kind == "AppSearchResult", let app = item.lockup,
                  let id = Int64(app.adamId ?? ""), id > 0,
                  let offer = app.buttonAction?.purchaseConfiguration,
                  offer.metricsPlatformDisplayStyle == "vision", offer.appPlatforms?.contains("vision") == true,
                  seen.insert(id).inserted else { return nil }
            return StoreApp(id: id, name: app.title ?? "", bundleID: app.bundleId ?? "", version: "", artworkURL: nil)
        }
        let apps = Array(matches.prefix(12))
        guard !apps.isEmpty else { return apps }
        let ids = apps.map { String($0.id) }.joined(separator: ",")
        let details = (try? await catalog("/lookup", query: ["id": ids, "country": country, "entity": "xrosSoftware"])) ?? []
        let byID = details.reduce(into: [Int64: StoreApp]()) { $0[$1.trackId] = $1.app }
        return apps.map { byID[$0.id] ?? $0 }
    }

    private func fetch(_ url: URL) async throws -> (Data, URL?) {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IPATool.CommandError("The App Store search request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return (data, response.url)
    }

    private struct CatalogResponse: Decodable { let results: [CatalogApp] }

    private struct CatalogApp: Decodable {
        let trackId: Int64
        let trackName: String?
        let bundleId: String?
        let version: String?
        let artworkUrl100: URL?
        let supportedDevices: [String]?

        var app: StoreApp {
            StoreApp(id: trackId, name: trackName ?? "", bundleID: bundleId ?? "",
                     version: version ?? "", artworkURL: artworkUrl100)
        }
    }

    private struct VisionPage: Decodable {
        let data: [Page]
        struct Page: Decodable { let data: Shelves }
        struct Shelves: Decodable { let shelves: [Shelf]? }
        struct Shelf: Decodable { let items: [Item]? }
        struct Item: Decodable {
            let kind: String?
            let lockup: Lockup?
            enum CodingKeys: String, CodingKey { case kind = "$kind", lockup }
        }
        struct Lockup: Decodable {
            let adamId: String?
            let bundleId: String?
            let title: String?
            let buttonAction: ButtonAction?
        }
        struct ButtonAction: Decodable {
            let purchaseConfiguration: PurchaseConfiguration?
        }
        struct PurchaseConfiguration: Decodable {
            let appPlatforms: [String]?
            let metricsPlatformDisplayStyle: String?
        }
    }
}
