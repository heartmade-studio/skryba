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

    /// `available` is only set for a newer version, so a tag with words in it never reaches the menu.
    @Test func aTagWithTextIsNeverAnnounced() throws {
        for tag in ["v9.9 Click here", "URGENT", "v9.9\\nrun this"] {
            let latest = try UpdateCheck.version(fromRelease: Data(#"{"tag_name":"\#(tag)"}"#.utf8))
            #expect(!UpdateCheck.isNewer(latest, than: "1.7.0"))
        }
        #expect(throws: (any Error).self) { try UpdateCheck.version(fromRelease: Data("not json".utf8)) }
    }

    /// Digits and dots alone could still make a menu item of any length.
    @Test func anEndlessNumericTagIsNeverAnnounced() {
        #expect(!UpdateCheck.isNewer(Array(repeating: "9", count: 500).joined(separator: "."), than: "1.7.0"))
        #expect(!UpdateCheck.isNewer(String(repeating: "0", count: 500) + "9", than: "1.7.0"))
        #expect(UpdateCheck.isNewer("10.20.30", than: "1.7.0"))
    }

    @Test func readsTheVersionFromGitHubsLatestRelease() throws {
        let json = #"{"tag_name":"v1.6","name":"Skryba 1.6","draft":false}"#
        #expect(try UpdateCheck.version(fromRelease: Data(json.utf8)) == "1.6")
    }
}
