import Foundation
import Testing
@testable import Skryba

struct UpdateCheckTests {
    @Test func comparesVersionsNumberByNumber() {
        #expect(UpdateCheck.isNewer("1.6", than: "1.5.2"))
        #expect(UpdateCheck.isNewer("1.5.1", than: "1.5"))
        #expect(UpdateCheck.isNewer("1.10", than: "1.9"))
        #expect(!UpdateCheck.isNewer("1.5", than: "1.5.0"))
        #expect(!UpdateCheck.isNewer("1.5", than: "1.5.2"))
        #expect(!UpdateCheck.isNewer("1.6-beta", than: "1.5"))
        #expect(!UpdateCheck.isNewer("", than: "1.5"))
    }

    @Test func readsTheVersionFromGitHubsLatestRelease() throws {
        let json = #"{"tag_name":"v1.6","name":"Skryba 1.6","draft":false}"#
        #expect(try UpdateCheck.version(fromRelease: Data(json.utf8)) == "1.6")
    }
}
