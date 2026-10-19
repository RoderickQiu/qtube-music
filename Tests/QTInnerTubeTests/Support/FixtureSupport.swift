import Foundation
import Testing
@testable import QTInnerTube

/// Recorded anonymous InnerTube responses (see Fixtures/README.md).
enum Fixture {
    static var folder: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    /// Source folder (for re-recording with `QT_LIVE=1 QT_RECORD=1`).
    static var sourceFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name + ".json"))
    }

    static func json(_ name: String) throws -> QTJSON {
        try QTJSON(data: data(name))
    }
}

enum QTLive {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["QT_LIVE"] == "1" }
    static var isRecording: Bool { isEnabled && ProcessInfo.processInfo.environment["QT_RECORD"] == "1" }
}

/// Shrinks a live response to what the parsers read: drops tracking/logging/accessibility payloads and menus
/// (except the song-credits entry used for Song⇄Video), caps long item lists, truncates long texts and replaces
/// the anonymous visitor id.
enum FixtureTrimmer {
    static let droppedKeys: Set<String> = [
        "trackingParams", "clickTrackingParams", "loggingContext", "accessibility", "accessibilityData",
        "accessibilityPlayData", "accessibilityPauseData", "serializedShareEntity", "commandMetadata",
        "loggingDirectives", "frameworkUpdates", "adBreakHeartbeatParams", "playerOverlays", "reportFormModalRenderer",
        "playerOverlayRenderer", "multiSelectCheckbox", "shareEndpoint", "sharePanelCommand", "streamingData",
        "playbackTracking", "attestation", "storyboards", "heartbeatParams", "playerConfig", "adPlacements",
        "playerAds", "videoQualityPromoSupportedRenderers", "messages", "endscreen", "captions", "annotations",
        "cards", "trackingParamsAsString", "subscribeAccessibility", "unsubscribeAccessibility", "subheaders",
        "background", "playIcon", "pauseIcon", "playingIcon", "iconColor", "activeBackgroundColor",
        "loadingIndicatorColor", "iconLoadingColor", "activeScaleFactor", "buttonSize", "rippleTarget",
        "thumbnailCrop", "thumbnailScale", "contentPosition", "displayStyle", "toggledAccessibilityData",
        "queueNavigationEndpoint", "onDeselectedCommand", "addToToastAction", "modalEndpoint", "signInEndpoint",
        "feedbackEndpoint", "dismissalCommand", "itemHeight", "flexColumnDisplayStyle", "displayPriority",
        "contentsMultiSelectable", "collapsedItemCount", "likeButton",
    ]
    static let cappedItemKeys: Set<String> = [
        "musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "playlistPanelVideoRenderer",
        "musicNavigationButtonRenderer", "musicMultiRowListItemRenderer", "chipCloudChipRenderer",
    ]

    static func trim(_ json: QTJSON, cap: Int = 6) -> QTJSON {
        var out = json.removingKeys(droppedKeys)
        if out["responseContext"].object != nil { out = replacingResponseContext(out) }
        return out.transformed { node in
            switch node {
            case .object(var o):
                if let menu = o["menu"], menu["menuRenderer"].object != nil {
                    let keep = menu[path: "menuRenderer", "items"].array.filter {
                        QTParse.creditsVideoId(menu: ["menuRenderer": ["items": [$0]]]) != nil
                    }
                    o["menu"] = keep.isEmpty ? nil : ["menuRenderer": ["items": .array(keep)]]
                }
                for (k, v) in o {
                    if k == "text", case .string(let s) = v, s.count > 200 { o[k] = .string(String(s.prefix(200)) + "…") }
                    if k == "description" || k == "content", case .string(let s) = v, s.count > 200 {
                        o[k] = .string(String(s.prefix(200)) + "…")
                    }
                }
                return .object(o)
            case .array(let a):
                let items = a.filter { $0.rendererKey.map(cappedItemKeys.contains) == true }
                guard items.count > cap, items.count >= a.count - 1 else { return node }
                var kept = Array(a.prefix(cap))
                if let tail = a.last, tail["continuationItemRenderer"].object != nil { kept.append(tail) }
                return .array(kept)
            default:
                return node
            }
        }
    }

    /// Keeps only `logged_in` from the response context and replaces any visitor id with a placeholder.
    static func replacingResponseContext(_ json: QTJSON) -> QTJSON {
        guard case .object(var o) = json else { return json }
        var params: [QTJSON] = []
        for service in json[path: "responseContext", "serviceTrackingParams"].array {
            for p in service["params"].array where p["key"].string == "logged_in" { params.append(p) }
        }
        var context: [String: QTJSON] = ["serviceTrackingParams": [["service": "GFEEDBACK", "params": .array(params)]]]
        if json[path: "responseContext", "visitorData"].string != nil { context["visitorData"] = "QTFIXTUREVISITOR" }
        o["responseContext"] = .object(context)
        return .object(o)
    }
}

/// A transport that replays canned responses (by endpoint) and records requests.
final class FakeTransport: QTHTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [String: [Result<Reply, URLError>]] = [:]
    private(set) var requests: [URLRequest] = []

    /// Queue a reply for requests whose URL path ends with `endpoint` ("browse", "next", "/" for the web page).
    func enqueue(_ endpoint: String, _ reply: Result<Reply, URLError>) {
        lock.withLock { replies[endpoint, default: []].append(reply) }
    }

    func enqueue(_ endpoint: String, status: Int = 200, json: QTJSON, headers: [String: String] = [:]) {
        enqueue(endpoint, .success(Reply(status: status, body: (try? json.data()) ?? Data(), headers: headers)))
    }

    func enqueue(_ endpoint: String, status: Int = 200, data: Data, headers: [String: String] = [:]) {
        enqueue(endpoint, .success(Reply(status: status, body: data, headers: headers)))
    }

    var recorded: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let reply: Result<Reply, URLError>? = lock.withLock {
            requests.append(request)
            let key = replies.keys.sorted { $0.count > $1.count }.first { path.hasSuffix($0) }
            guard let key, var queue = replies[key], !queue.isEmpty else { return nil }
            let r = queue.removeFirst()
            replies[key] = queue
            return r
        }
        switch reply {
        case .success(let r)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                           headerFields: r.headers)!
            return (r.body, response)
        case .failure(let e)?:
            throw e
        case nil:
            throw URLError(.resourceUnavailable)
        }
    }
}

extension URLRequest {
    var jsonBody: QTJSON { (httpBody.flatMap { try? QTJSON(data: $0) }) ?? .null }
}
