import Foundation

private actor EngineStore {
  var pendingDevice: [String: Any] = [:]
  var playerCache: [String: (expires: TimeInterval, data: [String: Any])] = [:]
  var watchCache: [String: (expires: TimeInterval, data: [String: Any])] = [:]
  var homeCache: [String: (expires: TimeInterval, items: [[String: Any]])] = [:]
  var inflightPlayer: [String: Task<[String: Any], Never>] = [:]
  var visitorData: String = ""
  var visitorExpires: TimeInterval = 0

  private var dataDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("YouTubeCaNhan", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  func readJSON(_ name: String, fallback: [String: Any]) -> [String: Any] {
    let url = dataDir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return fallback }
    return obj
  }

  func writeJSON(_ name: String, dict: [String: Any]) {
    let url = dataDir.appendingPathComponent(name)
    if let data = try? JSONSerialization.data(withJSONObject: dict) {
      try? data.write(to: url, options: .atomic)
    }
  }

  func removeFile(_ name: String) {
    try? FileManager.default.removeItem(at: dataDir.appendingPathComponent(name))
  }

  func getPlayer(_ vid: String) -> [String: Any]? {
    let now = Date().timeIntervalSince1970
    if let hit = playerCache[vid], hit.expires > now { return hit.data }
    return nil
  }

  func setPlayer(_ vid: String, data: [String: Any]) {
    playerCache[vid] = (Date().timeIntervalSince1970 + 7200, data)
  }

  func clearPlayer(_ vid: String) {
    playerCache.removeValue(forKey: vid)
    watchCache.removeValue(forKey: vid)
  }

  func getOrStartPlayer(_ vid: String, factory: @escaping () async -> [String: Any]) -> Task<[String: Any], Never> {
    if let existing = inflightPlayer[vid] {
      return existing
    }
    let t = Task<[String: Any], Never> {
      await factory()
    }
    inflightPlayer[vid] = t
    return t
  }

  func finishInflightPlayer(_ vid: String) {
    inflightPlayer.removeValue(forKey: vid)
  }

  func getWatch(_ vid: String) -> [String: Any]? {
    let now = Date().timeIntervalSince1970
    if let hit = watchCache[vid], hit.expires > now { return hit.data }
    return nil
  }

  func setWatch(_ vid: String, data: [String: Any]) {
    watchCache[vid] = (Date().timeIntervalSince1970 + 7200, data)
  }

  func getHome(_ cat: String) -> (items: [[String: Any]], stale: Bool)? {
    let now = Date().timeIntervalSince1970
    if let hit = homeCache[cat], !hit.items.isEmpty {
      return (hit.items, hit.expires <= now)
    }
    if cat == "all" {
      let disk = readJSON("home_cache.json", fallback: [:])
      if let items = disk["items"] as? [[String: Any]], !items.isEmpty {
        let savedAt = disk["savedAt"] as? TimeInterval ?? 0
        homeCache["all"] = (savedAt + 240, items)
        return (items, savedAt + 240 <= now)
      }
    }
    return nil
  }

  func setHome(_ cat: String, items: [[String: Any]]) {
    let now = Date().timeIntervalSince1970
    homeCache[cat] = (now + 240, items)
    if cat == "all" {
      writeJSON("home_cache.json", dict: ["savedAt": now, "items": items])
    }
  }

  func clearHome() {
    homeCache.removeAll()
    removeFile("home_cache.json")
  }

  func setPendingDevice(_ dict: [String: Any]) {
    pendingDevice = dict
  }

  func getPendingDeviceCode() -> String? {
    pendingDevice["device_code"] as? String
  }

  func getVisitorData() -> String? {
    let now = Date().timeIntervalSince1970
    if !visitorData.isEmpty && visitorExpires > now { return visitorData }
    return nil
  }

  func setVisitorData(_ vd: String) {
    visitorData = vd
    visitorExpires = Date().timeIntervalSince1970 + 3600
  }
}

final class YouTubeLocalEngine {
  private let store = EngineStore()

  private let tvClientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
  private let tvClientSecret = "SboVhoG9s0rNafixCSGGKXAT"
  private let tvScope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
  private let iosUA = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
  private let visionUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

  private let categoryQueries: [String: String] = [
    "all": "xu hướng việt nam hot nhất hôm nay",
    "music": "nhạc trẻ việt nam hot nhất hiện nay official mv",
    "remix": "nhạc trẻ remix hay nhất hiện nay nonstop",
    "lofi": "lofi chill tiếng việt nhẹ nhàng dễ ngủ",
    "podcast": "podcast tiếng việt hay nhất tâm lý phát triển bản thân",
    "gaming": "gaming việt nam highlight mới nhất",
    "news": "tin tức thời sự việt nam mới nhất hôm nay",
    "comedy": "hài kịch việt nam mới nhất triệu view",
    "tech": "đánh giá công nghệ iphone mới nhất",
    "live": "nhạc chill trực tiếp 24/7 lofi hip hop"
  ]

  private let adKeys: Set<String> = [
    "adSlotRenderer", "adBadgeViewModel", "promotedSparklesWebRenderer",
    "promotedVideoRenderer", "searchPyvRenderer", "adPlacementRenderer",
    "inFeedAdLayoutRenderer", "playerAds"
  ]

  // MARK: - HTTP Router

  func handleHTTP(_ req: LocalHTTPRequest) async -> LocalHTTPResponse {
    if req.method == "OPTIONS" {
      return LocalHTTPResponse.raw(
        status: 204,
        reason: "No Content",
        headers: [
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, HEAD, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Range"
        ],
        body: Data()
      )
    }

    let path = req.path
    let qItems = req.query

    if !path.hasPrefix("/api/") {
      return serveStatic(path: path)
    }

    switch path {
    case "/api/pin/check":
      return .json(["required": false, "unlocked": true])

    case "/api/info":
      return .json(["lanUrl": "http://127.0.0.1:18899", "tunnelUrl": "", "port": 18899])

    case "/api/profile":
      let def: [String: Any] = ["history": [], "liked": [], "watchLater": [], "subscriptions": [], "playlists": []]
      if req.method == "POST",
         let incoming = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
        var cur = await store.readJSON("profile.json", fallback: def)
        for k in ["history", "liked", "watchLater", "subscriptions", "playlists"] {
          if let arr = incoming[k] as? [Any] { cur[k] = Array(arr.prefix(300)) }
        }
        await store.writeJSON("profile.json", dict: cur)
        return .json(["ok": true])
      } else {
        let cur = await store.readJSON("profile.json", fallback: def)
        return .json(cur)
      }

    case "/api/suggest":
      let list = await fetchSuggestions(qItems["q"] ?? "")
      return .json(list)

    case "/api/home":
      let cat = qItems["category"] ?? "all"
      let force = qItems["refresh"] == "1"
      let items = await fetchHome(category: cat, forceRefresh: force)
      return .json(["items": items, "category": cat])

    case "/api/shorts":
      let tree = await innertubeWeb("search", payload: ["query": "#shorts xu hướng việt nam âm nhạc hài"])
      return .json(["items": extractVideos(from: tree, limit: 24)])

    case "/api/search":
      let q = (qItems["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if let directId = parseYouTubeID(q) {
        let w = await fetchPlayer(videoId: directId)
        let durSec = w["durationSeconds"] as? Int ?? 0
        let durTxt = durSec > 0 ? String(format: "%d:%02d", durSec / 60, durSec % 60) : ""
        let item: [String: Any] = [
          "id": directId,
          "title": w["title"] as? String ?? "YouTube Video",
          "channel": w["channel"] as? String ?? "YouTube",
          "channelId": w["channelId"] as? String ?? "",
          "channelAvatar": "",
          "views": "",
          "published": "",
          "duration": durTxt,
          "isLive": w["isLive"] as? Bool ?? false,
          "resumePercent": 0,
          "thumbnail": "https://i.ytimg.com/vi/\(directId)/hqdefault.jpg"
        ]
        return .json(["directVideoId": directId, "channels": [], "items": [item]])
      } else {
        let tree = await innertubeWeb("search", payload: ["query": q])
        return .json([
          "directVideoId": NSNull(),
          "channels": [],
          "items": extractVideos(from: tree, limit: 30)
        ])
      }

    case "/api/auth/status":
      let auth = await store.readJSON("google_auth.json", fallback: [:])
      let hasToken = !(auth["refresh_token"] as? String ?? "").isEmpty || !(auth["access_token"] as? String ?? "").isEmpty
      if hasToken {
        return .json([
          "loggedIn": true,
          "account": auth["account"] ?? NSNull(),
          "accounts": auth["accounts"] ?? []
        ])
      }
      return .json(["loggedIn": false, "account": NSNull(), "accounts": []])

    case "/api/auth/device/start":
      let res = await startDeviceAuth()
      return .json(res, status: res["userCode"] != nil ? 200 : 502)

    case "/api/auth/device/poll":
      let res = await pollDeviceAuth()
      return .json(res)

    case "/api/auth/select-account":
      var pid = qItems["pageId"] ?? ""
      var cname = qItems["name"] ?? ""
      if pid.isEmpty && cname.isEmpty,
         let incoming = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
        pid = incoming["pageId"] as? String ?? ""
        cname = incoming["name"] as? String ?? ""
      }
      var auth = await store.readJSON("google_auth.json", fallback: [:])
      if let accs = auth["accounts"] as? [[String: Any]],
         let match = accs.first(where: {
           ($0["pageId"] as? String ?? "") == pid && (cname.isEmpty || ($0["name"] as? String ?? "") == cname)
         }) {
        auth["account"] = match
        await store.writeJSON("google_auth.json", dict: auth)
      }
      await store.clearHome()
      return .json(["ok": true, "account": auth["account"] ?? NSNull()])

    case "/api/auth/logout":
      await store.removeFile("google_auth.json")
      await store.clearHome()
      return .json(["ok": true])

    case "/api/account/history":
      return .json(await fetchAccountBrowse("FEhistory", fallbackKey: "history"))

    case "/api/account/liked":
      return .json(await fetchAccountBrowse("VLLL", fallbackKey: "liked"))

    case "/api/account/subscriptions":
      return .json(await fetchAccountBrowse("FEsubscriptions", fallbackKey: "subscriptions"))

    default:
      if path.hasPrefix("/api/stream/") {
        let vid = String(path.dropFirst("/api/stream/".count))
        return await handleStream(videoId: vid, req: req)
      } else if path.hasPrefix("/api/player/") {
        let vid = String(path.dropFirst("/api/player/".count))
        return .json(await fetchPlayer(videoId: vid))
      } else if path.hasPrefix("/api/watch/") {
        let vid = String(path.dropFirst("/api/watch/".count))
        return .json(await fetchWatch(videoId: vid))
      } else if path.hasPrefix("/api/prefetch/") {
        let vid = String(path.dropFirst("/api/prefetch/".count))
        _ = await fetchPlayer(videoId: vid)
        return .json(["ok": true])
      } else if path.hasPrefix("/api/channel/") {
        let bid = String(path.dropFirst("/api/channel/".count))
        return .json(await fetchChannel(browseId: bid))
      }
      return .json(["detail": "Not found"], status: 404)
    }
  }

  // MARK: - Media Stream Handler (302 Native HLS / Direct CDN + 206 Range Proxy Fallback)

  private func pickURLFromMap(_ map: [String: String]?, desiredQ: Int) -> String? {
    guard let map, !map.isEmpty else { return nil }
    let heights = map.keys.compactMap(Int.init).sorted()
    let le = heights.filter { $0 <= desiredQ }
    let chosen = le.last ?? heights.first
    return chosen.flatMap { map["\($0)"] }
  }

  private func handleStream(videoId: String, req: LocalHTTPRequest) async -> LocalHTTPResponse {
    let mediaType = req.query["type"] ?? "audio"
    let q = Int(req.query["q"] ?? "720") ?? 720
    let forceProxy = req.query["proxy"] == "1"

    let p = await fetchPlayer(videoId: videoId)
    let isLive = p["isLive"] as? Bool ?? false
    if isLive, let hls = p["hlsUrl"] as? String, !hls.isEmpty {
      return .redirect(hls)
    }

    let directAudio = p["directAudioUrl"] as? String ?? ""
    let directVideos = p["directVideoUrls"] as? [String: String]
    let hlsAudio = p["hlsAudioUrl"] as? String ?? ""
    let hlsVideos = p["hlsVideoUrls"] as? [String: String]

    // Fast path: 302 redirect to native Apple HLS .m3u8 (instant seek, 0% 403) or direct CDN MP4
    if !forceProxy {
      let targetURLStr: String
      if mediaType == "video" {
        targetURLStr = pickURLFromMap(hlsVideos, desiredQ: q)
          ?? pickURLFromMap(directVideos, desiredQ: q)
          ?? (!hlsAudio.isEmpty ? hlsAudio : directAudio)
      } else {
        targetURLStr = !hlsAudio.isEmpty ? hlsAudio : directAudio
      }
      guard !targetURLStr.isEmpty else {
        return .json(["detail": "Stream unavailable"], status: 404)
      }
      return .redirect(targetURLStr)
    }

    // Proxy fallback path: RFC 7233 206 Partial Content on raw MP4 (never slice .m3u8)
    let targetURLStr: String
    let fallbackMime: String
    if mediaType == "video" {
      targetURLStr = pickURLFromMap(directVideos, desiredQ: q) ?? directAudio
      fallbackMime = "video/mp4"
    } else {
      targetURLStr = directAudio
      fallbackMime = "audio/mp4"
    }
    guard !targetURLStr.isEmpty else {
      return .json(["detail": "Stream unavailable"], status: 404)
    }
    guard let upstreamURL = URL(string: targetURLStr) else {
      return .json(["detail": "Bad stream URL"], status: 502)
    }
    var upReq = URLRequest(url: upstreamURL, timeoutInterval: 15.0)
    upReq.httpMethod = req.method == "HEAD" ? "HEAD" : "GET"
    upReq.setValue(visionUA, forHTTPHeaderField: "User-Agent")

    let rangeHdr = req.headers["range"] ?? "bytes=0-524287"
    if rangeHdr.hasPrefix("bytes=") {
      let spec = String(rangeHdr.dropFirst(6)).split(separator: ",", maxSplits: 1).first.map(String.init) ?? "0-524287"
      let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
      if bounds.count == 2, let start = Int64(bounds[0]) {
        let reqEnd = Int64(bounds[1])
        let cappedEnd = reqEnd.map { min($0, start + 524287) } ?? (start + 524287)
        upReq.setValue("bytes=\(start)-\(cappedEnd)", forHTTPHeaderField: "Range")
      } else {
        upReq.setValue(rangeHdr, forHTTPHeaderField: "Range")
      }
    }

    guard let (data, resp) = try? await URLSession.shared.data(for: upReq),
          let http = resp as? HTTPURLResponse
    else {
      return .json(["detail": "Upstream stream error"], status: 502)
    }

    if http.statusCode == 403 || http.statusCode == 410 {
      await store.clearPlayer(videoId)
    }

    var outHdrs: [String: String] = [
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store",
      "Content-Type": http.value(forHTTPHeaderField: "Content-Type") ?? fallbackMime,
      "Access-Control-Allow-Origin": "*"
    ]
    if let cr = http.value(forHTTPHeaderField: "Content-Range") {
      outHdrs["Content-Range"] = cr
    }
    if req.method == "HEAD", let cl = http.value(forHTTPHeaderField: "Content-Length") {
      outHdrs["Content-Length"] = cl
    }

    return LocalHTTPResponse.raw(
      status: http.statusCode,
      reason: http.statusCode == 206 ? "Partial Content" : "OK",
      headers: outHdrs,
      body: req.method == "HEAD" ? Data() : data
    )
  }

  private func serveStatic(path: String) -> LocalHTTPResponse {
    let rel: String
    if path == "/" {
      rel = "index.html"
    } else if path == "/apple-touch-icon.png" {
      rel = "icons/apple-touch-icon.png"
    } else if path.hasPrefix("/static/") {
      rel = String(path.dropFirst("/static/".count))
    } else {
      rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    guard let root = Bundle.main.resourceURL?.appendingPathComponent("static", isDirectory: true) else {
      return LocalHTTPResponse.raw(status: 404, reason: "Not Found", headers: ["Content-Type": "text/plain"], body: Data())
    }
    let fileURL = root.appendingPathComponent(rel)
    let targetURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : root.appendingPathComponent("index.html")
    let data = (try? Data(contentsOf: targetURL)) ?? Data()
    let ext = targetURL.pathExtension.lowercased()
    let mime: String
    switch ext {
    case "html": mime = "text/html; charset=utf-8"
    case "css": mime = "text/css; charset=utf-8"
    case "js": mime = "application/javascript; charset=utf-8"
    case "png": mime = "image/png"
    case "webmanifest", "json": mime = "application/json; charset=utf-8"
    default: mime = "application/octet-stream"
    }
    return LocalHTTPResponse.raw(
      status: 200,
      reason: "OK",
      headers: ["Content-Type": mime, "Cache-Control": "no-cache"],
      body: data
    )
  }

  // MARK: - YouTube InnerTube & OAuth Calls Direct on iPhone IP

  private func parseYouTubeID(_ raw: String) -> String? {
    if raw.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return raw }
    let pattern = "(?:v=|youtu\\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
          let range = Range(match.range(at: 1), in: raw)
    else { return nil }
    return String(raw[range])
  }

  private func postJSON(_ urlStr: String, body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval = 10.0) async -> [String: Any] {
    guard let url = URL(string: urlStr),
          let payload = try? JSONSerialization.data(withJSONObject: body)
    else { return [:] }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.httpBody = payload
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("vi-VN,vi;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
  }

  private func innertubeWeb(_ endpoint: String, payload: [String: Any]) async -> [String: Any] {
    var body = payload
    body["context"] = [
      "client": [
        "clientName": "WEB",
        "clientVersion": "2.20261120.01.00",
        "hl": "vi",
        "gl": "VN"
      ]
    ]
    return await postJSON("https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", body: body)
  }

  private func innertubeTVAuth(_ endpoint: String, payload: [String: Any], token: String) async -> [String: Any] {
    let auth = await store.readJSON("google_auth.json", fallback: [:])
    let pageId = (auth["account"] as? [String: Any])?["pageId"] as? String ?? ""
    var ctx: [String: Any] = [
      "client": [
        "clientName": "TVHTML5",
        "clientVersion": "7.20261120.16.00",
        "hl": "vi",
        "gl": "VN"
      ]
    ]
    if !pageId.isEmpty { ctx["user"] = ["onBehalfOfUser": pageId] }
    var body = payload
    body["context"] = ctx
    return await postJSON(
      "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false",
      body: body,
      headers: ["Authorization": "Bearer \(token)", "Origin": "https://www.youtube.com"]
    )
  }

  private func fetchHome(category: String, forceRefresh: Bool = false) async -> [[String: Any]] {
    if !forceRefresh, let cached = await store.getHome(category) {
      if cached.stale {
        Task.detached(priority: .utility) { [weak self] in
          _ = await self?.fetchHomeFromNetwork(category: category)
        }
      }
      return cached.items
    }
    return await fetchHomeFromNetwork(category: category)
  }

  private func fetchHomeFromNetwork(category: String) async -> [[String: Any]] {
    var items: [[String: Any]] = []
    if category == "all", let tok = await validGoogleToken(), !tok.isEmpty {
      let tree = await innertubeTVAuth("browse", payload: ["browseId": "FEwhat_to_watch"], token: tok)
      items = extractVideos(from: tree, limit: 30)
    }

    if items.count < 6 {
      if category == "all" {
        async let r1 = innertubeWeb("search", payload: ["query": "nhạc trẻ việt nam hot nhất 2026 mv"])
        async let r2 = innertubeWeb("search", payload: ["query": "video xu hướng việt nam mới nhất hôm nay"])
        let (t1, t2) = await (r1, r2)
        let l1 = extractVideos(from: t1, limit: 16)
        let l2 = extractVideos(from: t2, limit: 16)
        var seen = Set<String>()
        for i in 0..<max(l1.count, l2.count) {
          if i < l1.count, let id = l1[i]["id"] as? String, seen.insert(id).inserted { items.append(l1[i]) }
          if i < l2.count, let id = l2[i]["id"] as? String, seen.insert(id).inserted { items.append(l2[i]) }
        }
      } else {
        let q = categoryQueries[category] ?? category
        let tree = await innertubeWeb("search", payload: ["query": q])
        items = extractVideos(from: tree, limit: 30)
      }
    }

    if !items.isEmpty {
      await store.setHome(category, items: items)
    }
    return items
  }

  private func fetchSuggestions(_ q: String) async -> [String] {
    guard !q.isEmpty,
          let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&hl=vi&gl=VN&ds=yt&q=\(enc)")
    else { return [] }
    let req = URLRequest(url: url, timeoutInterval: 5.0)
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let text = String(data: data, encoding: .utf8),
          let s = text.firstIndex(of: "("),
          let e = text.lastIndex(of: ")")
    else { return [] }
    let sub = String(text[text.index(after: s)..<e])
    guard let arr = try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [Any],
          arr.count > 1,
          let items = arr[1] as? [[Any]]
    else { return [] }
    return items.compactMap { $0.first as? String }
  }

  private func fetchVisitorData() async -> String {
    if let cached = await store.getVisitorData() {
      return cached
    }
    let res = await postJSON(
      "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false",
      body: [
        "context": [
          "client": [
            "clientName": "VISIONOS",
            "clientVersion": "1.02",
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
            "hl": "vi",
            "gl": "VN"
          ]
        ]
      ],
      headers: [
        "User-Agent": visionUA,
        "X-YouTube-Client-Name": "101",
        "X-YouTube-Client-Version": "1.02"
      ],
      timeout: 8.0
    )
    let vd = ((res["responseContext"] as? [String: Any])?["visitorData"] as? String) ?? ""
    if !vd.isEmpty {
      await store.setVisitorData(vd)
    }
    return vd
  }

  private func queryPlayerVisionOS(videoId: String) async -> [String: Any] {
    let vd = await fetchVisitorData()
    var client: [String: Any] = [
      "clientName": "VISIONOS",
      "clientVersion": "1.02",
      "deviceMake": "Apple",
      "deviceModel": "RealityDevice17,1",
      "osName": "visionOS",
      "osVersion": "26.5.23O471",
      "hl": "vi",
      "gl": "VN"
    ]
    var hdrs: [String: String] = [
      "User-Agent": visionUA,
      "X-YouTube-Client-Name": "101",
      "X-YouTube-Client-Version": "1.02"
    ]
    if !vd.isEmpty {
      client["visitorData"] = vd
      hdrs["X-Goog-Visitor-Id"] = vd
    }
    return await postJSON(
      "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
      body: [
        "videoId": videoId,
        "context": ["client": client],
        "contentCheckOk": true,
        "racyCheckOk": true
      ],
      headers: hdrs
    )
  }

  private func extractQuotedAttr(_ line: String, key: String) -> String? {
    let token = "\(key)=\""
    guard let start = line.range(of: token)?.upperBound else { return nil }
    guard let end = line[start...].firstIndex(of: "\"") else { return nil }
    return String(line[start..<end])
  }

  private func parseHLSManifest(_ manifestUrl: String) async -> (audioUrl: String, videoUrls: [String: String]) {
    guard let url = URL(string: manifestUrl) else { return ("", [:]) }
    var req = URLRequest(url: url, timeoutInterval: 10.0)
    req.setValue(visionUA, forHTTPHeaderField: "User-Agent")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse,
          http.statusCode == 200,
          let text = String(data: data, encoding: .utf8)
    else { return ("", [:]) }

    let lines = text.components(separatedBy: .newlines)
    var bestAudio = ""
    var bestAudioScore = -1
    var videoUrls: [String: String] = [:]
    var videoScores: [String: Int] = [:]

    var idx = 0
    while idx < lines.count {
      let line = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
        if let uri = extractQuotedAttr(line, key: "URI"), !uri.isEmpty {
          let gid = extractQuotedAttr(line, key: "GROUP-ID") ?? ""
          let isDefault = line.contains("DEFAULT=YES")
          let score = (isDefault ? 10 : 0) + (gid == "234" ? 5 : (gid == "233" ? 1 : 2))
          if score > bestAudioScore {
            bestAudioScore = score
            bestAudio = uri
          }
        }
      } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
        let codecs = extractQuotedAttr(line, key: "CODECS") ?? ""
        if codecs.contains("avc1"),
           let resStart = line.range(of: "RESOLUTION=")?.upperBound {
          let tail = line[resStart...]
          let resToken = tail.prefix { $0 != "," && $0 != " " }
          let parts = resToken.split(separator: "x")
          if parts.count == 2, let h = Int(parts[1]) {
            var nextIdx = idx + 1
            while nextIdx < lines.count && lines[nextIdx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              nextIdx += 1
            }
            if nextIdx < lines.count {
              let uri = lines[nextIdx].trimmingCharacters(in: .whitespacesAndNewlines)
              if uri.hasPrefix("http") {
                let key = "\(h)"
                let score = codecs.contains("mp4a.40.2") ? 2 : 1
                if score > (videoScores[key] ?? 0) {
                  videoScores[key] = score
                  videoUrls[key] = uri
                }
              }
            }
          }
        }
      }
      idx += 1
    }
    return (bestAudio, videoUrls)
  }

  private func queryPlayerClient(videoId: String, useAndroidVR: Bool) async -> [String: Any] {
    if useAndroidVR {
      let ua = "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
      return await postJSON(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        body: [
          "videoId": videoId,
          "context": [
            "client": [
              "clientName": "ANDROID_VR",
              "clientVersion": "1.62.27",
              "deviceMake": "Oculus",
              "deviceModel": "Quest 3",
              "osName": "Android",
              "osVersion": "12L",
              "androidSdkVersion": 32,
              "hl": "vi",
              "gl": "VN"
            ]
          ]
        ],
        headers: ["User-Agent": ua, "X-YouTube-Client-Name": "28"]
      )
    } else {
      return await postJSON(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        body: [
          "videoId": videoId,
          "context": [
            "client": [
              "clientName": "IOS",
              "clientVersion": "20.10.4",
              "deviceMake": "Apple",
              "deviceModel": "iPhone16,2",
              "osName": "iPhone",
              "osVersion": "18.3.2.22D82",
              "hl": "vi",
              "gl": "VN"
            ]
          ]
        ],
        headers: ["User-Agent": iosUA, "X-YouTube-Client-Name": "5"]
      )
    }
  }

  private func parsePlayerStreams(_ pData: [String: Any]) -> (audioUrl: String, videoUrls: [String: String], qualities: [Int], hls: String?) {
    let sd = pData["streamingData"] as? [String: Any] ?? [:]
    let af = sd["adaptiveFormats"] as? [[String: Any]] ?? []
    var audioUrl = ""
    var bestBitrate = 0
    var videoUrls: [String: String] = [:]
    var qualities = Set<Int>()

    for f in af {
      guard let u = f["url"] as? String, let mime = f["mimeType"] as? String else { continue }
      let br = f["bitrate"] as? Int ?? 0
      if mime.contains("audio/mp4") && br >= bestBitrate {
        bestBitrate = br
        audioUrl = u
      } else if mime.contains("video/mp4") && mime.contains("avc1"), let h = f["height"] as? Int {
        qualities.insert(h)
        if videoUrls["\(h)"] == nil { videoUrls["\(h)"] = u }
      }
    }
    return (audioUrl, videoUrls, qualities.sorted(), sd["hlsManifestUrl"] as? String)
  }

  private func fetchPlayer(videoId: String) async -> [String: Any] {
    if let hit = await store.getPlayer(videoId) {
      return hit
    }

    let task = await store.getOrStartPlayer(videoId) { [weak self] in
      guard let self else { return [:] }
      // Primary: VISIONOS with its own visitorData (zero PO-token 403 on mid-video seek + native Apple HLS VOD)
      var pData = await self.queryPlayerVisionOS(videoId: videoId)
      var parsed = self.parsePlayerStreams(pData)
      if parsed.audioUrl.isEmpty && parsed.hls == nil {
        let iosData = await self.queryPlayerClient(videoId: videoId, useAndroidVR: false)
        let iosParsed = self.parsePlayerStreams(iosData)
        if !iosParsed.audioUrl.isEmpty || iosParsed.hls != nil {
          pData = iosData
          parsed = iosParsed
        }
      }
      if parsed.audioUrl.isEmpty && parsed.hls == nil {
        let vrData = await self.queryPlayerClient(videoId: videoId, useAndroidVR: true)
        let vrParsed = self.parsePlayerStreams(vrData)
        if !vrParsed.audioUrl.isEmpty || vrParsed.hls != nil {
          pData = vrData
          parsed = vrParsed
        }
      }

      let vd = pData["videoDetails"] as? [String: Any] ?? [:]
      let isLive = vd["isLiveContent"] as? Bool ?? false
      var hlsAudioUrl = ""
      var hlsVideoUrls: [String: String] = [:]
      if !isLive, let hls = parsed.hls, !hls.isEmpty {
        let hlsParsed = await self.parseHLSManifest(hls)
        hlsAudioUrl = hlsParsed.audioUrl
        hlsVideoUrls = hlsParsed.videoUrls
      }

      var mergedQ = Set(parsed.qualities)
      for k in hlsVideoUrls.keys {
        if let h = Int(k) { mergedQ.insert(h) }
      }

      let out: [String: Any] = [
        "id": videoId,
        "title": vd["title"] as? String ?? "",
        "channel": vd["author"] as? String ?? "YouTube",
        "channelId": vd["channelId"] as? String ?? "",
        "description": vd["shortDescription"] as? String ?? "",
        "durationSeconds": Int(vd["lengthSeconds"] as? String ?? "0") ?? 0,
        "isLive": isLive,
        "thumbnail": "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
        "qualities": mergedQ.sorted(),
        "hlsUrl": parsed.hls ?? NSNull(),
        "hlsAudioUrl": hlsAudioUrl,
        "hlsVideoUrls": hlsVideoUrls,
        "directAudioUrl": parsed.audioUrl,
        "directVideoUrls": parsed.videoUrls
      ]

      if !hlsAudioUrl.isEmpty || !parsed.audioUrl.isEmpty || parsed.hls != nil {
        await self.store.setPlayer(videoId, data: out)
      }
      return out
    }

    let res = await task.value
    await store.finishInflightPlayer(videoId)
    return res
  }

  private func fetchWatch(videoId: String) async -> [String: Any] {
    if let hit = await store.getWatch(videoId) {
      return hit
    }

    async let playerReq = fetchPlayer(videoId: videoId)
    async let nextReq = innertubeWeb("next", payload: ["videoId": videoId])
    async let sponsorReq = fetchSponsorSegments(videoId)

    let (pOut, nData, segs) = await (playerReq, nextReq, sponsorReq)

    let p1 = findFirstDict(in: nData, key: "videoPrimaryInfoRenderer") ?? [:]
    let p2 = findFirstDict(in: nData, key: "videoSecondaryInfoRenderer") ?? [:]
    let vc = (p1["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any] ?? [:]
    let owner = (p2["owner"] as? [String: Any])?["videoOwnerRenderer"] as? [String: Any] ?? [:]

    let pTitle = runsText(p1["title"])
    let views = {
      let v = runsText(vc["shortViewCount"])
      return v.isEmpty ? runsText(vc["viewCount"]) : v
    }()
    let published = {
      let p = runsText(p1["relativeDateText"])
      return p.isEmpty ? runsText(p1["dateText"]) : p
    }()
    let ownerName = runsText(owner["title"])
    let channelId = (((owner["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String)
      ?? (pOut["channelId"] as? String ?? "")
    let avThumbs = ((owner["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
    let channelAvatar = avThumbs.last?["url"] as? String ?? ""
    let subscribers = runsText(owner["subscriberCountText"])
    let desc = ((p2["attributedDescription"] as? [String: Any])?["content"] as? String)
      ?? (pOut["description"] as? String ?? "")

    let related = extractVideos(from: nData, limit: 22).filter { ($0["id"] as? String) != videoId }

    var out = pOut
    if !pTitle.isEmpty { out["title"] = pTitle }
    if !ownerName.isEmpty { out["channel"] = ownerName }
    out["channelId"] = channelId
    out["channelAvatar"] = channelAvatar
    out["subscribers"] = subscribers
    out["views"] = views
    out["published"] = published
    out["description"] = desc
    out["sponsorSegments"] = segs
    out["related"] = related

    let hasAudio = !(pOut["directAudioUrl"] as? String ?? "").isEmpty
    let hasHls = !(pOut["hlsUrl"] is NSNull) && (pOut["hlsUrl"] as? String)?.isEmpty == false
    if hasAudio || hasHls {
      await store.setWatch(videoId, data: out)
    }
    return out
  }

  private func fetchChannel(browseId: String) async -> [String: Any] {
    let tree = await innertubeWeb("browse", payload: ["browseId": browseId])
    let header = findFirstDict(in: tree, key: "pageHeaderViewModel") ?? [:]
    let name = runsText(((header["title"] as? [String: Any])?["dynamicTextViewModel"] as? [String: Any])?["text"])
    let avSources = (((((header["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any])?["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
    let bannerSources = (((header["banner"] as? [String: Any])?["imageBannerViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []

    var videos = extractVideos(from: tree, limit: 28)
    if videos.count < 6 && !name.isEmpty {
      let sTree = await innertubeWeb("search", payload: ["query": name])
      let extra = extractVideos(from: sTree, limit: 20)
      var seen = Set(videos.compactMap { $0["id"] as? String })
      for v in extra {
        if let id = v["id"] as? String, seen.insert(id).inserted { videos.append(v) }
      }
    }

    return [
      "channelId": browseId,
      "name": name.isEmpty ? "Kênh YouTube" : name,
      "avatar": avSources.last?["url"] as? String ?? "",
      "banner": bannerSources.last?["url"] as? String ?? "",
      "items": videos
    ]
  }

  private func fetchSponsorSegments(_ videoId: String) async -> [[String: Any]] {
    let cats = "%5B%22sponsor%22,%22selfpromo%22,%22interaction%22,%22music_offtopic%22%5D"
    guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=\(cats)") else {
      return []
    }
    let req = URLRequest(url: url, timeoutInterval: 2.0)
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return rows.compactMap { r in
      guard let nums = r["segment"] as? [NSNumber], nums.count == 2 else { return nil }
      let s0 = nums[0].doubleValue
      let s1 = nums[1].doubleValue
      guard s1 - s0 >= 1.0 else { return nil }
      return ["start": s0, "end": s1, "category": r["category"] as? String ?? "sponsor"]
    }
  }

  // MARK: - Google OAuth2 Device Flow

  private func validGoogleToken() async -> String? {
    var auth = await store.readJSON("google_auth.json", fallback: [:])
    let now = Date().timeIntervalSince1970
    if let tok = auth["access_token"] as? String,
       let exp = auth["expires_at"] as? Double, exp > now + 60 {
      return tok
    }
    guard let refresh = auth["refresh_token"] as? String, !refresh.isEmpty else { return nil }
    let r = await postJSON("https://www.youtube.com/o/oauth2/token", body: [
      "client_id": tvClientId,
      "client_secret": tvClientSecret,
      "refresh_token": refresh,
      "grant_type": "refresh_token"
    ])
    guard let newTok = r["access_token"] as? String else { return nil }
    auth["access_token"] = newTok
    auth["expires_at"] = now + Double(r["expires_in"] as? Int ?? 3500)
    await store.writeJSON("google_auth.json", dict: auth)
    return newTok
  }

  private func startDeviceAuth() async -> [String: Any] {
    let r = await postJSON("https://www.youtube.com/o/oauth2/device/code", body: [
      "client_id": tvClientId,
      "scope": tvScope,
      "device_id": UUID().uuidString,
      "device_model": "ytlr::"
    ])
    guard let dc = r["device_code"] as? String, let uc = r["user_code"] as? String else { return [:] }
    await store.setPendingDevice([
      "device_code": dc,
      "expires_at": Date().timeIntervalSince1970 + Double(r["expires_in"] as? Int ?? 1800)
    ])
    return [
      "userCode": uc,
      "verificationUrl": r["verification_url"] as? String ?? "https://www.google.com/device",
      "expiresIn": r["expires_in"] as? Int ?? 1800,
      "interval": r["interval"] as? Int ?? 5
    ]
  }

  private func pollDeviceAuth() async -> [String: Any] {
    guard let code = await store.getPendingDeviceCode() else { return ["status": "expired"] }

    let r = await postJSON("https://www.youtube.com/o/oauth2/token", body: [
      "client_id": tvClientId,
      "client_secret": tvClientSecret,
      "code": code,
      "grant_type": "http://oauth.net/grant_type/device/1.0"
    ])
    if let err = r["error"] as? String {
      return err == "authorization_pending" || err == "slow_down"
        ? ["status": "pending"]
        : ["status": "error", "error": err]
    }
    guard let tok = r["access_token"] as? String else { return ["status": "pending"] }
    let baseAuth: [String: Any] = [
      "access_token": tok,
      "refresh_token": r["refresh_token"] as? String ?? "",
      "expires_at": Date().timeIntervalSince1970 + Double(r["expires_in"] as? Int ?? 3500),
      "account": ["name": "Tài khoản Google", "handle": "", "avatar": "", "pageId": ""],
      "accounts": []
    ]
    await store.writeJSON("google_auth.json", dict: baseAuth)
    let accTree = await innertubeTVAuth("account/accounts_list", payload: ["accountReadMask": ["returnOwner": true]], token: tok)
    let accounts = extractAccounts(from: accTree)
    let selected = accounts.first ?? ["name": "Tài khoản Google", "handle": "", "avatar": "", "pageId": ""]
    var finalAuth = baseAuth
    finalAuth["account"] = selected
    finalAuth["accounts"] = accounts
    await store.writeJSON("google_auth.json", dict: finalAuth)
    await store.setPendingDevice([:])
    await store.clearHome()
    return ["status": "connected", "account": selected, "accounts": accounts]
  }

  private func fetchAccountBrowse(_ browseId: String, fallbackKey: String) async -> [String: Any] {
    let local = ((await store.readJSON("profile.json", fallback: [:]))[fallbackKey] as? [[String: Any]]) ?? []
    guard let tok = await validGoogleToken(), !tok.isEmpty else {
      return ["loggedIn": false, "items": local]
    }
    let tree = await innertubeTVAuth("browse", payload: ["browseId": browseId], token: tok)
    let remote = extractVideos(from: tree, limit: 60)
    var merged: [[String: Any]] = []
    var seen = Set<String>()
    for x in local.prefix(5) {
      if let id = x["id"] as? String, seen.insert(id).inserted { merged.append(x) }
    }
    for v in remote {
      if let id = v["id"] as? String, seen.insert(id).inserted { merged.append(v) }
    }
    return ["loggedIn": true, "items": merged]
  }

  // MARK: - Recursive Tree Parsers

  private func findFirstDict(in node: Any, key: String) -> [String: Any]? {
    if let d = node as? [String: Any] {
      if let hit = d[key] as? [String: Any] { return hit }
      for v in d.values {
        if let found = findFirstDict(in: v, key: key) { return found }
      }
    } else if let arr = node as? [Any] {
      for elem in arr {
        if let found = findFirstDict(in: elem, key: key) { return found }
      }
    }
    return nil
  }

  private func runsText(_ node: Any?) -> String {
    guard let d = node as? [String: Any] else { return "" }
    if let s = d["simpleText"] as? String { return s }
    if let c = d["content"] as? String { return c }
    if let runs = d["runs"] as? [[String: Any]] {
      return runs.compactMap { $0["text"] as? String }.joined()
    }
    return ""
  }

  private func pickFastThumb(_ sources: [[String: Any]]?, videoId: String) -> String {
    if let sources, !sources.isEmpty {
      let chosen = sources.first(where: { ($0["width"] as? Int ?? 0) >= 320 }) ?? sources.last
      if var u = chosen?["url"] as? String, !u.isEmpty {
        if u.hasPrefix("//") { u = "https:" + u }
        return u
      }
    }
    return "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
  }

  private func extractAccounts(from tree: Any) -> [[String: Any]] {
    var out: [[String: Any]] = []
    func walk(_ n: Any) {
      if let d = n as? [String: Any] {
        if let air = d["accountItemRenderer"] as? [String: Any] {
          let name = runsText(air["accountName"])
          let handle = runsText(air["accountByline"])
          let thumbs = ((air["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
          let av = thumbs.last?["url"] as? String ?? ""
          var pid = ""
          if let toks = ((air["serviceEndpoint"] as? [String: Any])?["selectActiveIdentityEndpoint"] as? [String: Any])?["supportedTokens"] as? [[String: Any]] {
            for t in toks {
              if let pt = t["pageIdToken"] as? [String: Any], let p = pt["pageId"] as? String { pid = p }
            }
          }
          if !name.isEmpty {
            out.append([
              "name": name,
              "handle": handle,
              "avatar": av,
              "pageId": pid,
              "isSelected": air["isSelected"] as? Bool ?? false
            ])
          }
          return
        }
        for v in d.values { walk(v) }
      } else if let arr = n as? [Any] {
        for x in arr { walk(x) }
      }
    }
    walk(tree)
    return out
  }

  private func extractVideos(from tree: Any, limit: Int) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var seen = Set<String>()

    func walk(_ n: Any) {
      if out.count >= limit { return }
      if let d = n as? [String: Any] {
        if !adKeys.isDisjoint(with: d.keys) { return }

        if let vr = d["videoRenderer"] as? [String: Any],
           let vid = vr["videoId"] as? String, vid.count == 11, !seen.contains(vid) {
          let title = runsText(vr["title"])
          guard !title.isEmpty else { return }
          seen.insert(vid)
          let ownerRuns = ((vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
          let channel = ownerRuns.first?["text"] as? String ?? "YouTube"
          let channelId = (((ownerRuns.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String) ?? ""
          let chThumbs = ((((vr["channelThumbnailSupportedRenderers"] as? [String: Any])?["channelThumbnailWithLinkRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
          let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
          var resumePct = 0
          if let ovs = vr["thumbnailOverlays"] as? [[String: Any]] {
            for ov in ovs {
              if let rp = ov["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any],
                 let pct = rp["percentDurationWatched"] as? Int { resumePct = pct }
            }
          }
          out.append([
            "id": vid,
            "title": title,
            "channel": channel,
            "channelId": channelId,
            "channelAvatar": chThumbs.last?["url"] as? String ?? "",
            "views": runsText(vr["shortViewCountText"]),
            "published": runsText(vr["publishedTimeText"]),
            "duration": runsText(vr["lengthText"]),
            "isLive": false,
            "resumePercent": resumePct,
            "thumbnail": pickFastThumb(thumbs, videoId: vid)
          ])
          return
        }

        if let lv = d["lockupViewModel"] as? [String: Any] {
          let ctype = lv["contentType"] as? String ?? ""
          if !ctype.isEmpty && ctype != "LOCKUP_CONTENT_TYPE_VIDEO" && ctype != "LOCKUP_CONTENT_TYPE_SHORT" {
            return
          }
          let vid = (lv["contentId"] as? String) ??
            (((((lv["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String ?? ""
          guard vid.count == 11, !seen.contains(vid) else { return }

          let mvm = (lv["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] ?? [:]
          let title = runsText(mvm["title"])
          guard !title.isEmpty else { return }
          seen.insert(vid)

          var duration = ""
          var resumePct = 0
          let thumbVM = (lv["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
          let imgSources = (thumbVM?["image"] as? [String: Any])?["sources"] as? [[String: Any]]
          if let ovs = thumbVM?["overlays"] as? [[String: Any]] {
            for ov in ovs {
              if let bot = ov["thumbnailBottomOverlayViewModel"] as? [String: Any] {
                if let pb = (bot["progressBar"] as? [String: Any])?["thumbnailOverlayProgressBarViewModel"] as? [String: Any],
                   let sp = pb["startPercent"] as? Int { resumePct = sp }
                if let badges = bot["badges"] as? [[String: Any]] {
                  for b in badges {
                    if let txt = (b["thumbnailBadgeViewModel"] as? [String: Any])?["text"] as? String, !txt.isEmpty {
                      duration = txt
                      break
                    }
                  }
                }
              }
            }
          }

          let decAv = (mvm["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any] ?? [:]
          let avSources = ((((decAv["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]]) ?? []
          let channelId = ((((decAv["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
          let cidStr = channelId?["browseId"] as? String ?? ""

          var channel = "YouTube"
          var views = ""
          var published = ""
          if let rows = ((mvm["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] {
            if let p0 = rows.first?["metadataParts"] as? [[String: Any]], let first = p0.first {
              let c = runsText(first["text"])
              if !c.isEmpty { channel = c }
            }
            if rows.count > 1, let p1 = rows[1]["metadataParts"] as? [[String: Any]] {
              if let v0 = p1.first { views = runsText(v0["text"]) }
              if p1.count > 1 { published = runsText(p1[1]["text"]) }
            }
          }

          out.append([
            "id": vid,
            "title": title,
            "channel": channel,
            "channelId": cidStr,
            "channelAvatar": avSources.last?["url"] as? String ?? "",
            "views": views,
            "published": published,
            "duration": duration,
            "isLive": duration.uppercased().contains("TRỰC TIẾP") || duration.uppercased().contains("LIVE"),
            "resumePercent": resumePct,
            "thumbnail": pickFastThumb(imgSources, videoId: vid)
          ])
          return
        }

        if let tr = d["tileRenderer"] as? [String: Any] {
          let vid = (tr["contentId"] as? String) ??
            (((tr["onSelectCommand"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String ?? "")
          guard vid.count == 11, !seen.contains(vid) else { return }
          let meta = (tr["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any] ?? [:]
          let title = runsText(meta["title"])
          guard !title.isEmpty else { return }
          seen.insert(vid)
          var duration = ""
          var resumePct = 0
          let header = tr["header"] as? [String: Any]
          let thumbs = ((header?["tileHeaderRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
          if let ovs = (header?["tileHeaderRenderer"] as? [String: Any])?["thumbnailOverlays"] as? [[String: Any]] {
            for ov in ovs {
              if let ts = ov["thumbnailOverlayTimeStatusRenderer"] as? [String: Any] {
                duration = runsText(ts["text"])
              }
              if let rp = ov["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any],
                 let pct = rp["percentDurationWatched"] as? Int { resumePct = pct }
            }
          }
          out.append([
            "id": vid,
            "title": title,
            "channel": "YouTube",
            "channelId": "",
            "channelAvatar": "",
            "views": "",
            "published": "",
            "duration": duration,
            "isLive": false,
            "resumePercent": resumePct,
            "thumbnail": pickFastThumb(thumbs, videoId: vid)
          ])
          return
        }

        for v in d.values { walk(v) }
      } else if let arr = n as? [Any] {
        for x in arr { walk(x) }
      }
    }
    walk(tree)
    return out
  }
}
