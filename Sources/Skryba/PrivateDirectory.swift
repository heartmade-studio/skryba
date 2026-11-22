import Foundation

extension FileManager {
    /// A folder only this user can open. `createDirectory` applies permissions only to a folder it
    /// creates, so an existing one is tightened as well.
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
