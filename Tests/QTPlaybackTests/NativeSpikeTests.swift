import AVFoundation
import Foundation
import QTInnerTube
import Testing
@testable import QTPlayback

/// M5 native-engine spike: the offline, deterministic parts (response parsing, format choice, cipher parsing,
/// client table, spectrum bands). The live parts run in `swift run QTNativeSpike` (docs/native-engine-spike.md).
@Suite struct NativeSpikeTests {
    /// Shaped like a signed-in Premium WEB_REMIX `player` response (synthetic values, no real URLs or ids).
    static let premiumResponse = """
    {"playabilityStatus":{"status":"OK"},
     "videoDetails":{"lengthSeconds":"213"},
     "streamingData":{"expiresInSeconds":"21540","serverAbrStreamingUrl":"https://example.invalid/sabr",
      "adaptiveFormats":[
       {"itag":137,"mimeType":"video/mp4; codecs=\\"avc1.640028\\"","bitrate":4000000},
       {"itag":140,"mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":130000,"contentLength":"3449447",
        "signatureCipher":"s=ABC%3D%3D&sp=sig&url=https%3A%2F%2Fexample.invalid%2Fvideoplayback%3Fitag%3D140%26n%3Dxyz"},
       {"itag":141,"mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":260000,"contentLength":"6858879",
        "signatureCipher":"s=DEF&sp=sig&url=https%3A%2F%2Fexample.invalid%2Fvideoplayback%3Fitag%3D141"},
       {"itag":774,"mimeType":"audio/webm; codecs=\\"opus\\"","bitrate":280000,
        "signatureCipher":"s=GHI&sp=sig&url=https%3A%2F%2Fexample.invalid%2Fvideoplayback%3Fitag%3D774"},
       {"itag":599,"mimeType":"audio/mp4; codecs=\\"mp4a.40.5\\"","bitrate":300000,"isDrc":true,
        "url":"https://example.invalid/videoplayback?itag=599"}
      ]}}
    """

    @Test func parsesAudioFormatsAndPicksTheBestAVFoundationOne() throws {
        let json = try QTJSON(data: Data(Self.premiumResponse.utf8))
        let r = QTNativePlayerResponse.parse(json, client: .webRemix, signedIn: true)
        #expect(r.playability == .ok)
        #expect(r.audioFormats.map(\.itag) == [140, 141, 774, 599])     // video formats dropped
        #expect(r.hasServerABR)
        #expect(r.durationSeconds == 213)
        // AAC 256 wins; Opus/WebM (higher bitrate) isn't AVFoundation-playable; DRC is skipped.
        #expect(r.bestPlayableAudio?.itag == 141)
        #expect(r.bestAudioAnyCodec?.itag == 774)
        #expect(r.audioFormats.first { $0.itag == 774 }?.isAVFoundationPlayable == false)
        #expect(r.audioFormats.first { $0.itag == 140 }?.codec == "mp4a.40.2")
        #expect(r.audioFormats.first { $0.itag == 140 }?.urlHasNParameter == true)
        #expect(r.audioFormats.first { $0.itag == 141 }?.urlHasNParameter == false)
    }

    @Test func mapsPlayabilityStatuses() throws {
        func status(_ s: String) throws -> QTNativePlayability {
            let json = try QTJSON(data: Data(#"{"playabilityStatus":{"status":"\#(s)","reason":"r"}}"#.utf8))
            return QTNativePlayerResponse.parse(json, client: .iOS, signedIn: false).playability
        }
        #expect(try status("LOGIN_REQUIRED") == .loginRequired("r"))
        #expect(try status("UNPLAYABLE") == .unplayable("r"))
        #expect(try status("ERROR") == .error("ERROR: r"))
    }

    @Test func parsesSignatureCipher() throws {
        let cipher = "s=AB%3DC&sp=sig&url=https%3A%2F%2Fexample.invalid%2Fvideoplayback%3Fitag%3D140%26n%3Dxyz"
        let parts = try #require(QTNativePlayerScript.parseSignatureCipher(cipher))
        #expect(parts.s == "AB=C")
        #expect(parts.sp == "sig")
        #expect(parts.url.host == "example.invalid")
        #expect(parts.url.queryItems?.first { $0.name == "n" }?.value == "xyz")
        #expect(QTNativePlayerScript.parseSignatureCipher("sp=sig") == nil)
    }

    @Test func clientTableIsConsistent() {
        let all = QTNativeStreamClient.all
        #expect(Set(all.map(\.shortName)).count == all.count)
        #expect(QTNativeStreamClient.named("tv") == .tvSamsung)
        #expect(QTNativeStreamClient.named("web_remix") == .webRemix)
        // Only cookie-capable clients ever see the session; mobile/VR clients never get it.
        #expect(QTNativeStreamClient.webRemix.supportsCookies && QTNativeStreamClient.webRemix.needsPlayerScript)
        #expect(!QTNativeStreamClient.iOS.supportsCookies && !QTNativeStreamClient.androidVR.supportsCookies)
    }

    @Test func spectrumPeaksAtTheToneFrequency() throws {
        let sink = QTNativeTapSink()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        for c in 0..<2 {
            let ch = buffer.floatChannelData![c]
            for i in 0..<4096 { ch[i] = 0.5 * sin(2 * .pi * 1000 * Float(i) / 44_100) }
        }
        sink.consume(buffer)
        let bands = sink.bands(24, sampleRate: 44_100)
        #expect(bands.count == 24)
        let peak = try #require(bands.indices.max { bands[$0] < bands[$1] })
        // Band edges: 40 Hz · (16 kHz / 40 Hz)^(i/24); 1 kHz falls in band 12.
        #expect(abs(peak - 12) <= 1)
        #expect(sink.firstSignal != nil)
    }

    @Test func nativeEngineStaysUnavailableInTheApp() {
        #expect(QTNativePlaybackEngine.isAvailable == false)
        #expect(QTPlaybackEngineSelector.kind(tier: .premium, usesMockData: false) == .web)
    }
}
