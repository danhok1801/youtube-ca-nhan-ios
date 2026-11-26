import Foundation
import WebKit

final class YouTubeLocalEngine: NSObject, WKURLSchemeHandler {
  private var activeTasks = Set<ObjectIdentifier>()
  private let stateLock = NSLock()
  private var pendingDevice: [String: Any] = [:]
  private var playerCache: [String: (expires: TimeInterval, data: [String: Any])] = [:]
  private var watchCache: [String: (expires: TimeInterval, data: [String: Any])] = [:]
  private var homeCache: [String: (expires: TimeInterval, items: [[String: Any]])] = [:]
  private var inflightPlayer: [String: Task<[String: Any], Never>] = [:]
  private var inflightHome: [String: Task<[[String: Any]], Never>] = [:]

  private lazy var fastSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 8.0
    cfg.timeoutIntervalForResource = 15.0
    cfg.httpMaximumConnectionsPerHost = 12
    cfg.httpShouldUsePipelining = true
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  private lazy var sponsorSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 1.8
    cfg.timeoutIntervalForResource = 2.2
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  private let tvClientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
  private let tvClientSecret = "SboVhoG9s0rNafixCSGGKXAT"
  private let tvScope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"

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

  override init() {
    super.init()
    // Warm up disk cache & network connection immediately on app launch
    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let disk = self.readJSONFile("home_cache.json", fallback: [:])
      if let items = disk["items"] as? [[String: Any]], !items.isEmpty {
        let savedAt = disk["savedAt"] as? TimeInterval ?? 0
        self.stateLock.lock()
        self.homeCache["all"] = (savedAt + 180, items)
        self.stateLock.unlock()
      }
      _ = await self.fetchHomeFromNetwork(category: "all")
    }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let taskObj = urlSchemeTask as AnyObject
    let id = ObjectIdentifier(taskObj)
    activeTasks.insert(id)

    let reqURL = urlSchemeTask.request.url
    let method = urlSchemeTask.request.httpMethod ?? "GET"
    let bodyData = urlSchemeTask.request.httpBody

    Task {
      await self.handle(task: urlSchemeTask, id: id, url: reqURL, method: method, body: bodyData)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let id = ObjectIdentifier(urlSchemeTask as AnyObject)
    activeTasks.remove(id)
  }

  @MainActor
  private func finishOnMain(
    task: WKURLSchemeTask,
    id: ObjectIdentifier,
    url: URL?,
    status: Int,
    mime: String,
    data: Data
  ) {
    guard activeTasks.remove(id) != nil, let reqURL = url else { return }
    let headers = [
      "Content-Type": mime,
      "Content-Length": "\(data.count)",
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-store"
    ]
    if let resp = HTTPURLResponse(url: reqURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
      task.didReceive(resp)
      task.didReceive(data)
      task.didFinish()
    }
  }

  private func finishJSON(task: WKURLSchemeTask, id: ObjectIdentifier, url: URL?, status: Int = 200, obj: Any) async {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    await finishOnMain(task: task, id: id, url: url, status: status, mime: "application/json; charset=utf-8", data: data)
  }

  // MARK: - Storage Helpers

  private var dataDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("YouTubeCaNhan", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func readJSONFile(_ name: String, fallback: [String: Any]) -> [String: Any] {
    stateLock.lock()
    defer { stateLock.unlock() }
    let url = dataDir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return fallback }
    return obj
  }

  private func writeJSONFile(_ name: String, dict: [String: Any]) {
    stateLock.lock()
    defer { stateLock.unlock() }
    let url = dataDir.appendingPathComponent(name)
    if let data = try? JSONSerialization.data(withJSONObject: dict) {
      try? data.write(to: url, options: .atomic)
    }
  }

  func saveProfileFromBridge(_ incoming: [String: Any]) {
    let def: [String: Any] = ["history": [], "liked": [], "watchLater": [], "subscriptions": [], "playlists": []]
    var cur = readJSONFile("profile.json", fallback: def)
    for k in ["history", "liked", "watchLater", "subscriptions", "playlists"] {
      if let arr = incoming[k] as? [Any] { cur[k] = Array(arr.prefix(300)) }
    }
    writeJSONFile("profile.json", dict: cur)
  }

  // MARK: - Router

  private func handle(task: WKURLSchemeTask, id: ObjectIdentifier, url: URL?, method: String, body: Data?) async {
    guard let reqURL = url,
          let comps = URLComponents(url: reqURL, resolvingAgainstBaseURL: false)
    else { return }

    let path = comps.path.isEmpty ? "/index.html" : comps.path
    let qItems = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    if !path.hasPrefix("/api/") {
      await serveStatic(path: path, task: task, id: id, url: reqURL)
      return
    }

    switch path {
    case "/api/pin/check":
      await finishJSON(task: task, id: id, url: reqURL, obj: ["required": false, "unlocked": true])

    case "/api/info":
      await finishJSON(task: task, id: id, url: reqURL, obj: ["lanUrl": "ytlocal://app", "tunnelUrl": "", "port": 0])

    case "/api/profile":
      let def: [String: Any] = ["history": [], "liked": [], "watchLater": [], "subscriptions": [], "playlists": []]
      if method == "POST", let b = body,
         let incoming = try? JSONSerialization.jsonObject(with: b) as? [String: Any] {
        saveProfileFromBridge(incoming)
        await finishJSON(task: task, id: id, url: reqURL, obj: ["ok": true])
      } else {
        await finishJSON(task: task, id: id, url: reqURL, obj: readJSONFile("profile.json", fallback: def))
      }

    case "/api/suggest":
      let q = qItems["q"] ?? ""
      let list = await fetchSuggestions(q)
      await finishJSON(task: task, id: id, url: reqURL, obj: list)

    case "/api/home":
      let cat = qItems["category"] ?? "all"
      let force = qItems["refresh"] == "1"
      let items = await fetchHome(category: cat, forceRefresh: force)
      await finishJSON(task: task, id: id, url: reqURL, obj: ["items": items, "category": cat])

    case "/api/shorts":
      let tree = await innertubeWeb("search", payload: ["query": "#shorts xu hướng việt nam âm nhạc hài"])
      await finishJSON(task: task, id: id, url: reqURL, obj: ["items": extractVideos(from: tree, limit: 24)])

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
        await finishJSON(task: task, id: id, url: reqURL, obj: ["directVideoId": directId, "channels": [], "items": [item]])
      } else {
        let tree = await innertubeWeb("search", payload: ["query": q])
        await finishJSON(task: task, id: id, url: reqURL, obj: [
          "directVideoId": NSNull(),
          "channels": [],
          "items": extractVideos(from: tree, limit: 30)
        ])
      }

    case "/api/auth/status":
      // Instant local auth read without blocking UI on OAuth refresh
      let auth = readJSONFile("google_auth.json", fallback: [:])
      let hasToken = !(auth["refresh_token"] as? String ?? "").isEmpty || !(auth["access_token"] as? String ?? "").isEmpty
      if hasToken {
        await finishJSON(task: task, id: id, url: reqURL, obj: [
          "loggedIn": true,
          "account": auth["account"] ?? NSNull(),
          "accounts": auth["accounts"] ?? []
        ])
      } else {
        await finishJSON(task: task, id: id, url: reqURL, obj: ["loggedIn": false, "account": NSNull(), "accounts": []])
      }

    case "/api/auth/device/start":
      let res = await startDeviceAuth()
      await finishJSON(task: task, id: id, url: reqURL, status: res["userCode"] != nil ? 200 : 502, obj: res)

    case "/api/auth/device/poll":
      let res = await pollDeviceAuth()
      await finishJSON(task: task, id: id, url: reqURL, obj: res)

    case "/api/auth/select-account":
      var pid = qItems["pageId"] ?? ""
      var cname = qItems["name"] ?? ""
      if pid.isEmpty && cname.isEmpty, let b = body,
         let incoming = try? JSONSerialization.jsonObject(with: b) as? [String: Any] {
        pid = incoming["pageId"] as? String ?? ""
        cname = incoming["name"] as? String ?? ""
      }
      var auth = readJSONFile("google_auth.json", fallback: [:])
      if let accs = auth["accounts"] as? [[String: Any]],
         let match = accs.first(where: {
           ($0["pageId"] as? String ?? "") == pid && (cname.isEmpty || ($0["name"] as? String ?? "") == cname)
         }) {
        auth["account"] = match
        writeJSONFile("google_auth.json", dict: auth)
      }
      stateLock.lock()
      homeCache.removeAll()
      stateLock.unlock()
      await finishJSON(task: task, id: id, url: reqURL, obj: ["ok": true, "account": auth["account"] ?? NSNull()])

    case "/api/auth/logout":
      stateLock.lock()
      try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("google_auth.json"))
      homeCache.removeAll()
      stateLock.unlock()
      await finishJSON(task: task, id: id, url: reqURL, obj: ["ok": true])

    case "/api/account/history":
      let items = await fetchAccountBrowse("FEhistory", fallbackKey: "history")
      await finishJSON(task: task, id: id, url: reqURL, obj: items)

    case "/api/account/liked":
      let items = await fetchAccountBrowse("VLLL", fallbackKey: "liked")
      await finishJSON(task: task, id: id, url: reqURL, obj: items)

    case "/api/account/subscriptions":
      let items = await fetchAccountBrowse("FEsubscriptions", fallbackKey: "subscriptions")
      await finishJSON(task: task, id: id, url: reqURL, obj: items)

    default:
      if path.hasPrefix("/api/player/") {
        let vid = String(path.dropFirst("/api/player/".count))
        let p = await fetchPlayer(videoId: vid)
        await finishJSON(task: task, id: id, url: reqURL, obj: p)
      } else if path.hasPrefix("/api/watch/") {
        let vid = String(path.dropFirst("/api/watch/".count))
        let detail = await fetchWatch(videoId: vid)
        await finishJSON(task: task, id: id, url: reqURL, obj: detail)
      } else if path.hasPrefix("/api/prefetch/") {
        let vid = String(path.dropFirst("/api/prefetch/".count))
        _ = await fetchPlayer(videoId: vid)
        await finishJSON(task: task, id: id, url: reqURL, obj: ["ok": true])
      } else if path.hasPrefix("/api/channel/") {
        let bid = String(path.dropFirst("/api/channel/".count))
        let ch = await fetchChannel(browseId: bid)
        await finishJSON(task: task, id: id, url: reqURL, obj: ch)
      } else {
        await finishJSON(task: task, id: id, url: reqURL, status: 404, obj: ["detail": "Not found"])
      }
    }
  }

  private func serveStatic(path: String, task: WKURLSchemeTask, id: ObjectIdentifier, url: URL?) async {
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
      await finishOnMain(task: task, id: id, url: url, status: 404, mime: "text/plain", data: Data())
      return
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
    await finishOnMain(task: task, id: id, url: url, status: 200, mime: mime, data: data)
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

  private func postJSON(_ urlStr: String, body: [String: Any], headers: [String: String] = [:]) async -> [String: Any] {
    guard let url = URL(string: urlStr),
          let payload = try? JSONSerialization.data(withJSONObject: body)
    else { return [:] }
    var req = URLRequest(url: url, timeoutInterval: 8.0)
    req.httpMethod = "POST"
    req.httpBody = payload
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("vi-VN,vi;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    guard let (data, _) = try? await fastSession.data(for: req),
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
    let auth = readJSONFile("google_auth.json", fallback: [:])
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
    let now = Date().timeIntervalSince1970
    stateLock.lock()
    let cached = homeCache[category]
    stateLock.unlock()

    if !forceRefresh, let hit = cached, !hit.items.isEmpty {
      if hit.expires <= now {
        Task.detached(priority: .utility) { [weak self] in
          _ = await self?.fetchHomeFromNetwork(category: category)
        }
      }
      return hit.items
    }
    return await fetchHomeFromNetwork(category: category)
  }

  private func fetchHomeFromNetwork(category: String) async -> [[String: Any]] {
    stateLock.lock()
    if let running = inflightHome[category] {
      stateLock.unlock()
      return await running.value
    }
    let task = Task<[[String: Any]], Never> { [weak self] in
      guard let self else { return [] }
      var items: [[String: Any]] = []
      if category == "all", let tok = await self.validGoogleToken(), !tok.isEmpty {
        let tree = await self.innertubeTVAuth("browse", payload: ["browseId": "FEwhat_to_watch"], token: tok)
        items = self.extractVideos(from: tree, limit: 30)
      }

      if items.count < 6 {
        if category == "all" {
          async let r1 = self.innertubeWeb("search", payload: ["query": "nhạc trẻ việt nam hot nhất 2026 mv"])
          async let r2 = self.innertubeWeb("search", payload: ["query": "video xu hướng việt nam mới nhất hôm nay"])
          let (t1, t2) = await (r1, r2)
          let l1 = self.extractVideos(from: t1, limit: 16)
          let l2 = self.extractVideos(from: t2, limit: 16)
          var seen = Set<String>()
          for i in 0..<max(l1.count, l2.count) {
            if i < l1.count, let id = l1[i]["id"] as? String, seen.insert(id).inserted { items.append(l1[i]) }
            if i < l2.count, let id = l2[i]["id"] as? String, seen.insert(id).inserted { items.append(l2[i]) }
          }
        } else {
          let q = self.categoryQueries[category] ?? category
          let tree = await self.innertubeWeb("search", payload: ["query": q])
          items = self.extractVideos(from: tree, limit: 30)
        }
      }

      if !items.isEmpty {
        let now = Date().timeIntervalSince1970
        self.stateLock.lock()
        self.homeCache[category] = (now + 240, items)
        self.stateLock.unlock()
        if category == "all" {
          self.writeJSONFile("home_cache.json", dict: ["savedAt": now, "items": items])
        }
      }
      return items
    }
    inflightHome[category] = task
    stateLock.unlock()

    let res = await task.value
    stateLock.lock()
    inflightHome.removeValue(forKey: category)
    stateLock.unlock()
    return res
  }

  private func fetchSuggestions(_ q: String) async -> [String] {
    guard !q.isEmpty,
          let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&hl=vi&gl=VN&ds=yt&q=\(enc)"),
          let (data, _) = try? await fastSession.data(from: url),
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
      let iosUA = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
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

  // Ultra-fast (~180ms) stream extraction ONLY (with single-flight deduplication)
  private func fetchPlayer(videoId: String) async -> [String: Any] {
    let now = Date().timeIntervalSince1970
    stateLock.lock()
    if let hit = playerCache[videoId], hit.expires > now {
      stateLock.unlock()
      return hit.data
    }
    if let running = inflightPlayer[videoId] {
      stateLock.unlock()
      return await running.value
    }
    let task = Task<[String: Any], Never> { [weak self] in
      guard let self else { return [:] }
      var pData = await self.queryPlayerClient(videoId: videoId, useAndroidVR: false)
      var parsed = self.parsePlayerStreams(pData)
      if parsed.audioUrl.isEmpty && parsed.hls == nil {
        let vrData = await self.queryPlayerClient(videoId: videoId, useAndroidVR: true)
        let vrParsed = self.parsePlayerStreams(vrData)
        if !vrParsed.audioUrl.isEmpty {
          pData = vrData
          parsed = vrParsed
        }
      }
      let vd = pData["videoDetails"] as? [String: Any] ?? [:]
      let out: [String: Any] = [
        "id": videoId,
        "title": vd["title"] as? String ?? "",
        "channel": vd["author"] as? String ?? "YouTube",
        "channelId": vd["channelId"] as? String ?? "",
        "description": vd["shortDescription"] as? String ?? "",
        "durationSeconds": Int(vd["lengthSeconds"] as? String ?? "0") ?? 0,
        "isLive": vd["isLiveContent"] as? Bool ?? false,
        "thumbnail": "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
        "qualities": parsed.qualities,
        "hlsUrl": parsed.hls ?? NSNull(),
        "directAudioUrl": parsed.audioUrl,
        "directVideoUrls": parsed.videoUrls
      ]
      if !parsed.audioUrl.isEmpty || parsed.hls != nil {
        self.stateLock.lock()
        self.playerCache[videoId] = (Date().timeIntervalSince1970 + 7200, out)
        self.stateLock.unlock()
      }
      return out
    }
    inflightPlayer[videoId] = task
    stateLock.unlock()

    let res = await task.value
    stateLock.lock()
    inflightPlayer.removeValue(forKey: videoId)
    stateLock.unlock()
    return res
  }

  private func fetchWatch(videoId: String) async -> [String: Any] {
    let now = Date().timeIntervalSince1970
    stateLock.lock()
    if let hit = watchCache[videoId], hit.expires > now {
      stateLock.unlock()
      return hit.data
    }
    stateLock.unlock()

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

    stateLock.lock()
    watchCache[videoId] = (now + 7200, out)
    stateLock.unlock()
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
    guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=\(cats)"),
          let (data, resp) = try? await sponsorSession.data(from: url),
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
    var auth = readJSONFile("google_auth.json", fallback: [:])
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
    writeJSONFile("google_auth.json", dict: auth)
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
    stateLock.lock()
    pendingDevice = [
      "device_code": dc,
      "expires_at": Date().timeIntervalSince1970 + Double(r["expires_in"] as? Int ?? 1800)
    ]
    stateLock.unlock()
    return [
      "userCode": uc,
      "verificationUrl": r["verification_url"] as? String ?? "https://www.google.com/device",
      "expiresIn": r["expires_in"] as? Int ?? 1800,
      "interval": r["interval"] as? Int ?? 5
    ]
  }

  private func pollDeviceAuth() async -> [String: Any] {
    stateLock.lock()
    let dc = pendingDevice["device_code"] as? String
    stateLock.unlock()
    guard let code = dc else { return ["status": "expired"] }

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
    writeJSONFile("google_auth.json", dict: baseAuth)
    let accTree = await innertubeTVAuth("account/accounts_list", payload: ["accountReadMask": ["returnOwner": true]], token: tok)
    let accounts = extractAccounts(from: accTree)
    let selected = accounts.first ?? ["name": "Tài khoản Google", "handle": "", "avatar": "", "pageId": ""]
    var finalAuth = baseAuth
    finalAuth["account"] = selected
    finalAuth["accounts"] = accounts
    writeJSONFile("google_auth.json", dict: finalAuth)
    stateLock.lock()
    pendingDevice = [:]
    homeCache.removeAll()
    stateLock.unlock()
    return ["status": "connected", "account": selected, "accounts": accounts]
  }

  private func fetchAccountBrowse(_ browseId: String, fallbackKey: String) async -> [String: Any] {
    let local = (readJSONFile("profile.json", fallback: [:])[fallbackKey] as? [[String: Any]]) ?? []
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
      // Pick the ~320-480px thumbnail for crisp mobile cards without downloading 1280px images
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
