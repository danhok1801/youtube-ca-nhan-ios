import Foundation
import Network

struct LocalHTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data
}

struct LocalHTTPResponse {
  let status: Int
  let reason: String
  let headers: [String: String]
  let body: Data

  static func json(_ obj: Any, status: Int = 200) -> LocalHTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return LocalHTTPResponse(
      status: status,
      reason: status == 200 ? "OK" : "Error",
      headers: [
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*"
      ],
      body: data
    )
  }

  static func redirect(_ location: String) -> LocalHTTPResponse {
    LocalHTTPResponse(
      status: 302,
      reason: "Found",
      headers: [
        "Location": location,
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*"
      ],
      body: Data()
    )
  }

  static func raw(status: Int, reason: String = "OK", headers: [String: String], body: Data) -> LocalHTTPResponse {
    LocalHTTPResponse(status: status, reason: reason, headers: headers, body: body)
  }
}

final class LocalHTTPServer {
  private let queue = DispatchQueue(label: "yt.local.http", qos: .userInitiated)
  private var listener: NWListener?
  private(set) var port: UInt16 = 0
  private let handler: (LocalHTTPRequest) async -> LocalHTTPResponse

  init(handler: @escaping (LocalHTTPRequest) async -> LocalHTTPResponse) {
    self.handler = handler
  }

  func start(onReady: @escaping (UInt16) -> Void) {
    if let listener, listener.state == .ready, port > 0 {
      DispatchQueue.main.async { onReady(self.port) }
      return
    }
    listener?.cancel()

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let preferredPort = NWEndpoint.Port(rawValue: self.port > 0 ? self.port : 18899) ?? .any
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: preferredPort)

    do {
      let l = try NWListener(using: params)
      self.listener = l
      var notified = false
      l.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        if case .ready = state, let p = l.port?.rawValue, p > 0 {
          self.port = p
          if !notified {
            notified = true
            DispatchQueue.main.async { onReady(p) }
          }
        } else if case .failed = state, !notified {
          notified = true
          self.startEphemeral(onReady: onReady)
        }
      }
      l.newConnectionHandler = { [weak self] conn in
        self?.accept(conn)
      }
      l.start(queue: queue)
    } catch {
      startEphemeral(onReady: onReady)
    }
  }

  private func startEphemeral(onReady: @escaping (UInt16) -> Void) {
    listener?.cancel()
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    if let l = try? NWListener(using: params) {
      self.listener = l
      var notified = false
      l.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        if case .ready = state, let p = l.port?.rawValue, p > 0 {
          self.port = p
          if !notified {
            notified = true
            DispatchQueue.main.async { onReady(p) }
          }
        }
      }
      l.newConnectionHandler = { [weak self] conn in
        self?.accept(conn)
      }
      l.start(queue: queue)
    }
  }

  func ensureRunning() {
    if let l = listener {
      switch l.state {
      case .ready, .setup, .waiting:
        return
      default:
        break
      }
    }
    start { _ in }
  }

  private func accept(_ conn: NWConnection) {
    conn.start(queue: queue)
    Task {
      await self.serveConnection(conn)
    }
  }

  private func receiveChunk(_ conn: NWConnection) async -> Data? {
    await withCheckedContinuation { cont in
      conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let data, !data.isEmpty {
          cont.resume(returning: data)
        } else if isComplete || error != nil {
          cont.resume(returning: nil)
        } else {
          cont.resume(returning: nil)
        }
      }
    }
  }

  private func sendAll(_ conn: NWConnection, data: Data) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      conn.send(content: data, completion: .contentProcessed { _ in
        cont.resume()
      })
    }
  }

  private func serveConnection(_ conn: NWConnection) async {
    defer { conn.cancel() }

    var buffer = Data()
    let sep = Data("\r\n\r\n".utf8)
    var headerEndRange: Range<Data.Index>?

    while headerEndRange == nil && buffer.count < 131072 {
      guard let chunk = await receiveChunk(conn) else { return }
      buffer.append(chunk)
      headerEndRange = buffer.range(of: sep)
    }
    guard let hdrRange = headerEndRange else { return }

    let headerData = buffer.subdata(in: buffer.startIndex..<hdrRange.lowerBound)
    guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
    let lines = headerStr.components(separatedBy: "\r\n")
    guard let firstLine = lines.first else { return }
    let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return }

    let method = parts[0].uppercased()
    let rawTarget = parts[1]

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let idx = line.firstIndex(of: ":") {
        let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
        let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        headers[k] = v
      }
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    var body = buffer.subdata(in: hdrRange.upperBound..<buffer.endIndex)
    while body.count < contentLength && body.count < 4 * 1024 * 1024 {
      guard let chunk = await receiveChunk(conn) else { break }
      body.append(chunk)
    }
    if body.count > contentLength && contentLength >= 0 {
      body = body.subdata(in: 0..<contentLength)
    }

    let comps = URLComponents(string: "http://127.0.0.1\(rawTarget)")
    let path = comps?.path.isEmpty == false ? (comps?.path ?? "/") : "/"
    var qMap: [String: String] = [:]
    for item in comps?.queryItems ?? [] {
      qMap[item.name] = item.value ?? ""
    }

    let req = LocalHTTPRequest(method: method, path: path, query: qMap, headers: headers, body: body)
    let resp = await handler(req)

    var outHeaders = resp.headers
    if outHeaders["Content-Length"] == nil {
      outHeaders["Content-Length"] = "\(resp.body.count)"
    }
    outHeaders["Connection"] = "close"

    var headText = "HTTP/1.1 \(resp.status) \(resp.reason)\r\n"
    for (k, v) in outHeaders {
      headText += "\(k): \(v)\r\n"
    }
    headText += "\r\n"

    var packet = Data(headText.utf8)
    if method != "HEAD" && !resp.body.isEmpty {
      packet.append(resp.body)
    }
    await sendAll(conn, data: packet)
  }
}
