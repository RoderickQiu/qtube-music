import Foundation
import QTAuth
import QTCore
import QTInnerTube

// QTDevSession — DEBUG-only developer tool for the shared dev session (HANDOFF §8). Never prints cookie values.
//
//   <cookie JSON on stdin> | swift run --scratch-path .build/<you> QTDevSession import
//       Imports Chrome DevTools `Network.getCookies` output (`{"cookies":[…]}`, a bare array, or a line starting
//       with `QTCOOKIES:` followed by either). Keeps only the allowlisted Google/YouTube auth cookies and stores them
//       in the shared dev Keychain item (QTDevSharedKeychainStore). Nothing touches the disk on the way.
//   QTDevSession status            Session present? cookie names, saved date, account (no values).
//   QTDevSession probe <endpoint> [browseId|query] [--hl zh-CN] [--params P]
//       One read-only request with the session; prints the JSON response to stdout (for exploring responses).
//   QTDevSession clear             Deletes the shared dev item.

#if DEBUG
@main
struct QTDevSessionTool {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage(); exit(2) }
        args.removeFirst()
        let store = QTSessionStore(store: QTDevSharedKeychainStore())
        do {
            switch command {
            case "import": try await importSession(store: store)
            case "status": try await status(store: store)
            case "probe": try await probe(store: store, args: args)
            case "ytcfg": try await ytcfg(store: store, keys: args)
            case "summary": try await summary(store: store, hl: args.first ?? "en")
            case "clear":
                try await store.clear()
                print("cleared")
            default: usage(); exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func usage() {
        FileHandle.standardError.write(Data("usage: QTDevSession import|status|probe <endpoint> [id]|clear\n".utf8))
    }

    static func importSession(store: QTSessionStore) async throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: input, as: UTF8.self)
        var payload = input
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("QTCOOKIES:") }) {
            payload = Data(line.dropFirst("QTCOOKIES:".count).utf8)
        }
        let cookies = QTAuthSession.filtered(try QTCookie.decodeCDP(payload))
        let session = QTAuthSession(cookies: cookies)
        guard session.isComplete else { throw QTAuthError.incompleteSession }
        try await store.save(session)
        print("imported \(cookies.count) cookies: \(Set(cookies.map(\.name)).sorted().joined(separator: ", "))")
        let client = QTInnerTubeClient(credentials: store)
        if let account = try? await client.account() {
            try await store.setAccount(account)
            print("account: \(account.name)")
        } else {
            print("account: (not readable)")
        }
    }

    static func status(store: QTSessionStore) async throws {
        guard let session = try await store.restore() else {
            print("no session")
            return
        }
        let names = session.cookies.map { "\($0.name)@\($0.bareDomainForDisplay)" }.sorted()
        print("session: \(session.cookies.count) cookies, saved \(session.savedAt.formatted())")
        print("cookies: \(names.joined(separator: ", "))")
        print("account: \(session.account?.name ?? "-") premium: \(session.account?.isPremium.map(String.init) ?? "-")")
    }

    /// Signed-in web client page: prints `ytcfg` keys matching the given substrings (never cookies).
    static func ytcfg(store: QTSessionStore, keys: [String]) async throws {
        guard try await store.restore() != nil, let creds = await store.credentials() else { throw QTInnerTubeError.notSignedIn }
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.setValue(QTInnerTubeConfiguration.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(creds.cookieHeader + "; SOCS=CAI", forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        let (data, _) = try await QTURLSessionTransport().send(request)
        let html = String(decoding: data, as: UTF8.self)
        let wanted = keys.isEmpty ? ["GL", "HL", "LOGGED_IN", "PREMIUM", "SUBSCRIBER", "MEMBER", "UNLIMITED"] : keys
        let pattern = try NSRegularExpression(pattern: "\"([A-Z0-9_]+)\"\\s*:\\s*(\"[^\"]{0,80}\"|true|false|[0-9]+)")
        var seen = Set<String>()
        for m in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let k = Range(m.range(at: 1), in: html), let v = Range(m.range(at: 2), in: html) else { continue }
            let key = String(html[k])
            guard wanted.contains(where: { key.contains($0) }), !key.contains("TOKEN"), !key.contains("SESSION"),
                  !key.contains("ID_TOKEN"), seen.insert(key).inserted else { continue }
            print("\(key) = \(html[v])")
        }
    }

    /// Read-only pass over the signed-in catalog: what each page parses to (titles and counts only).
    static func summary(store: QTSessionStore, hl: String) async throws {
        guard try await store.restore() != nil else { throw QTInnerTubeError.notSignedIn }
        let client = QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: hl), credentials: store)
        func line(_ s: String) { print(s) }
        func kinds(_ items: [QTShelfItem]) -> String {
            var c: [String: Int] = [:]
            for i in items {
                switch i {
                case .track: c["track", default: 0] += 1
                case .video: c["video", default: 0] += 1
                case .album: c["album", default: 0] += 1
                case .playlist: c["playlist", default: 0] += 1
                case .artist: c["artist", default: 0] += 1
                }
            }
            return c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        do {
            let home = try await client.home()
            line("home moods: \(home.feed.moods.map(\.title.resolved).joined(separator: " | "))")
            for s in home.feed.shelves { line("  shelf [\(s.style.rawValue)] \(s.title.resolved): \(kinds(s.items))") }
            line("  continuation: \(home.continuation != nil)")
        } catch { line("home error: \(error)") }
        do {
            let liked = try await client.likedSongs()
            line("liked: \(liked.playlist.tracks?.count ?? 0) first page, total \(liked.totalTrackCount.map(String.init) ?? "?"), continuation \(liked.continuation != nil), summary \(liked.summary ?? "-")")
            if let t = liked.playlist.tracks?.first { line("  first: \(t.title) — \(t.artistLine) [\(t.musicVideoType.rawValue)] album=\(t.album?.title ?? "-") id=\(t.album?.id ?? "-") dur=\(t.duration)") }
        } catch { line("liked error: \(error)") }
        do {
            let p = try await client.libraryPlaylists()
            line("library playlists: \(p.items.count) cont \(p.continuation != nil): \(p.items.prefix(8).map { "\($0.title.resolved) [\($0.id)]" }.joined(separator: " | "))")
            if let first = p.items.first(where: { $0.kind != .liked }) {
                let page = try await client.playlist(first.id)
                line("  playlist \(first.title.resolved): \(page.playlist.tracks?.count ?? 0) tracks, total \(page.totalTrackCount.map(String.init) ?? "?"), cont \(page.continuation != nil), owner \(page.playlist.owner ?? "-")")
            }
        } catch { line("library playlists error: \(error)") }
        do {
            let s = try await client.librarySongs()
            line("library songs: \(s.items.count) cont \(s.continuation != nil)")
        } catch { line("library songs error: \(error)") }
        do {
            let a = try await client.libraryAlbums()
            line("library albums: \(a.items.count) cont \(a.continuation != nil): \(a.items.prefix(4).map(\.title).joined(separator: " | "))")
        } catch { line("library albums error: \(error)") }
        do {
            let a = try await client.libraryArtists()
            line("library artists: \(a.items.count) cont \(a.continuation != nil): \(a.items.prefix(4).map(\.name).joined(separator: " | "))")
            if let artist = a.items.first {
                let page = try await client.artist(artist.id)
                line("  artist \(page.artist.name): songs \(page.songs.count) albums \(page.albums.count) singles \(page.singles.count) videos \(page.videos.count) playlists \(page.playlists.count) related \(page.relatedArtists.count) shelves \(page.shelves.map(\.title.resolved).joined(separator: " | "))")
            }
        } catch { line("library artists error: \(error)") }
        do {
            let r = try await client.search("周杰伦")
            line("search: top \(r.topResult.map { kinds([$0]) } ?? "-") items \(kinds(r.items))")
        } catch { line("search error: \(error)") }
        do {
            let e = try await client.explore()
            line("explore: destinations \(e.destinations.map(\.title.resolved).joined(separator: " | ")) moods \(e.moods.count)")
            for s in e.shelves { line("  shelf [\(s.style.rawValue)] \(s.title.resolved): \(kinds(s.items))") }
        } catch { line("explore error: \(error)") }
    }

    static func probe(store: QTSessionStore, args: [String]) async throws {
        guard try await store.restore() != nil else { throw QTInnerTubeError.notSignedIn }
        var positional: [String] = []
        var hl = "en"
        var params: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--hl": hl = args[i + 1]; i += 2
            case "--params": params = args[i + 1]; i += 2
            default: positional.append(args[i]); i += 1
            }
        }
        guard let endpoint = positional.first else { usage(); exit(2) }
        let client = QTInnerTubeClient(configuration: QTInnerTubeConfiguration(hl: hl), credentials: store)
        var body: [String: QTJSON] = [:]
        if positional.count > 1 {
            let value = positional[1]
            switch endpoint {
            case "search": body["query"] = .string(value)
            case "next": body["videoId"] = .string(value)
            case "browse" where value.hasPrefix("ctoken:"): body["continuation"] = .string(String(value.dropFirst(7)))
            default: body["browseId"] = .string(value)
            }
        }
        if let params { body["params"] = .string(params) }
        let json = try await client.send(endpoint, body: body)
        FileHandle.standardOutput.write(try json.data())
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

extension QTCookie {
    var bareDomainForDisplay: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
}
#else
@main
struct QTDevSessionTool {
    static func main() {
        FileHandle.standardError.write(Data("QTDevSession is available in debug builds only.\n".utf8))
        exit(1)
    }
}
#endif
