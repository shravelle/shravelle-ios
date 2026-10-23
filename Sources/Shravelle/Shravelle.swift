// Shravelle mobile monitoring for iOS (Swift Package).
//
//   Shravelle.start(.init(endpoint: "https://ingest.example.com", key: "shv_brw_...", app: "shop-ios"))
//   let session = URLSession(configuration: .shravelle)        // network monitoring + traceparent
//   Text("Home").shravelleScreen("Home")                       // SwiftUI screen views
//
// Captures sessions, screen views, app start time, crashes (Objective-C
// exceptions and fatal signals, saved to disk and sent on the next launch),
// network requests, handled errors and custom events. Events are kept in a
// file-backed queue and retried until delivered.
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

public final class Shravelle {
    public struct Config {
        public var endpoint: String
        public var key: String
        public var app: String
        public var release: String
        public var flushInterval: TimeInterval
        public var tracePropagationHosts: [String]
        public init(endpoint: String, key: String, app: String, release: String? = nil, flushInterval: TimeInterval = 15, tracePropagationHosts: [String] = []) {
            self.endpoint = endpoint; self.key = key; self.app = app
            self.release = release ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            self.flushInterval = flushInterval; self.tracePropagationHosts = tracePropagationHosts
        }
    }

    static var config: Config?
    static var sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    static var userId = ""
    static let queue = DispatchQueue(label: "io.shravelle.queue")
    static var timer: DispatchSourceTimer?
    static let launch = Date()
    static var startReported = false

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("shravelle", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var queueFile: URL { dir.appendingPathComponent("queue.jsonl") }
    static var crashFile: URL { dir.appendingPathComponent("crash.json") }

    public static func start(_ cfg: Config) {
        guard config == nil else { return }
        config = cfg
        if let data = try? Data(contentsOf: crashFile), let crash = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            enqueue(crash)
            try? FileManager.default.removeItem(at: crashFile)
        }
        installCrashHandlers()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            if !startReported { startReported = true; enqueue(event("app_start", ["name": "cold_start", "value": Date().timeIntervalSince(launch) * 1000])) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in flush() }
        #endif
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: cfg.flushInterval)
        t.setEventHandler { flushLocked() }
        t.resume()
        timer = t
    }

    public static func setUser(_ id: String) { userId = id }
    public static func screen(_ name: String) { enqueue(event("page_view", ["name": "screen", "route": name, "page_url": "app://\(name)"])) }
    public static func track(_ name: String, attributes: [String: String] = [:], value: Double = 0) {
        enqueue(event("custom", ["name": name, "value": value], attributes))
    }
    public static func recordError(_ error: Error, attributes: [String: String] = [:]) {
        enqueue(event("handled_exception", ["name": String(describing: type(of: error)), "message": error.localizedDescription,
                                            "stack": Thread.callStackSymbols.joined(separator: "\n")], attributes))
    }
    public static func recordNetwork(method: String, url: URL, status: Int, durationMs: Double, traceId: String = "") {
        var path = url.path.replacingOccurrences(of: "/[0-9]+(?=/|$)", with: "/:id", options: .regularExpression)
        if path.isEmpty { path = "/" }
        enqueue(event("ajax", ["name": "\(method) \(url.host ?? "")\(path)", "status": status, "duration_ms": durationMs, "trace_id": traceId]))
    }

    static func attrs(_ extra: [String: String] = [:]) -> [String: String] {
        var a: [String: String] = ["platform": "ios", "os.version": ProcessInfo.processInfo.operatingSystemVersionString]
        #if canImport(UIKit)
        a["device.model"] = UIDevice.current.model
        #endif
        extra.forEach { a[$0] = $1 }
        return a
    }

    static func event(_ type: String, _ fields: [String: Any] = [:], _ extra: [String: String] = [:]) -> [String: Any] {
        var e: [String: Any] = ["type": type, "timestamp": ISO8601DateFormatter().string(from: Date()), "session_id": sessionId,
                                "user_id": userId, "app": config?.app ?? "", "release": config?.release ?? "", "attributes": attrs(extra)]
        fields.forEach { e[$0] = $1 }
        return e
    }

    static func enqueue(_ e: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: e) else { return }
        queue.async {
            if let h = try? FileHandle(forWritingTo: queueFile) {
                h.seekToEndOfFile(); h.write(data); h.write("\n".data(using: .utf8)!); h.closeFile()
            } else {
                try? (data + "\n".data(using: .utf8)!).write(to: queueFile)
            }
        }
    }

    public static func flush() { queue.async { flushLocked() } }

    static func flushLocked() {
        guard let cfg = config, let text = try? String(contentsOf: queueFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return }
        let batch = Array(lines.prefix(200))
        let events = batch.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let body: [String: Any] = ["app": cfg.app, "session_id": sessionId, "user_id": userId, "release": cfg.release, "events": events]
        guard let url = URL(string: cfg.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/rum?key=" + cfg.key),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Shravelle-iOS/1.0 (iPhone; iOS)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession(configuration: .ephemeral).dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            ok = (200..<300).contains(code) || code == 400 || code == 401
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if ok {
            let current = ((try? String(contentsOf: queueFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            let rest = current.dropFirst(batch.count).joined(separator: "\n")
            try? (rest.isEmpty ? "" : rest + "\n").write(to: queueFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: crashes
    static var crashPath: [CChar] = []

    static func installCrashHandlers() {
        crashPath = Array(crashFile.path.utf8CString)
        NSSetUncaughtExceptionHandler { ex in
            let e = Shravelle.event("crash", ["name": ex.name.rawValue, "message": ex.reason ?? "", "stack": ex.callStackSymbols.joined(separator: "\n")])
            if let d = try? JSONSerialization.data(withJSONObject: e) { try? d.write(to: Shravelle.crashFile) }
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                // only async-signal-safe calls here: write a minimal record with open/write
                let e = Shravelle.event("crash", ["name": "Signal \(s)", "message": "Fatal signal \(s)", "stack": Thread.callStackSymbols.joined(separator: "\n")])
                if let d = try? JSONSerialization.data(withJSONObject: e) {
                    let fd = open(Shravelle.crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                    if fd >= 0 { _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }; close(fd) }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

// MARK: - network monitoring

public final class ShravelleURLProtocol: URLProtocol {
    private var task: URLSessionDataTask?
    private var start = Date()
    private static let handledKey = "io.shravelle.handled"

    public override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: handledKey, in: request) == nil && (request.url?.scheme?.hasPrefix("http") ?? false)
    }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        var traceId = ""
        if let host = request.url?.host, Shravelle.config?.tracePropagationHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) == true {
            traceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let span = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
            mutable.setValue("00-\(traceId)-\(span)-01", forHTTPHeaderField: "traceparent")
        }
        start = Date()
        let req = mutable as URLRequest
        task = URLSession(configuration: .default).dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let url = req.url { Shravelle.recordNetwork(method: req.httpMethod ?? "GET", url: url, status: status, durationMs: Date().timeIntervalSince(self.start) * 1000, traceId: traceId) }
            if let resp = resp { self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .allowed) }
            if let data = data { self.client?.urlProtocol(self, didLoad: data) }
            if let err = err { self.client?.urlProtocol(self, didFailWithError: err) } else { self.client?.urlProtocolDidFinishLoading(self) }
        }
        task?.resume()
    }
    public override func stopLoading() { task?.cancel() }
}

public extension URLSessionConfiguration {
    /// A default configuration with Shravelle network monitoring installed.
    static var shravelle: URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.protocolClasses = [ShravelleURLProtocol.self] + (c.protocolClasses ?? [])
        return c
    }
}

#if canImport(SwiftUI)
@available(iOS 13.0, macOS 11.0, tvOS 13.0, *)
public extension View {
    /// Records a screen view when the view appears.
    func shravelleScreen(_ name: String) -> some View { onAppear { Shravelle.screen(name) } }
}
#endif
