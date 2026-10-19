import Foundation
import QTCore
import Testing
@testable import QTInnerTube

@Suite struct ConfigurationTests {
    @Test func hlFollowsInterfaceLanguage() {
        #expect(QTInnerTubeConfiguration.hl(for: .zhHans) == "zh-CN")
        #expect(QTInnerTubeConfiguration.hl(for: .en) == "en")
        #expect(QTInnerTubeConfiguration().clientName == "WEB_REMIX")
    }

    @Test func fixturesFolderIsBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
