import Foundation

/// On-disk locations shared by the app, the control socket and remote clients.
public enum BamPaths {
    /// Directory name under Application Support holding bam.yaml.
    public static let configDirectoryName = "bam"
    /// Directory name under Application Support holding control.sock; differs from the config dir for compatibility with shipped clients.
    public static let socketDirectoryName = "me.harke.bam"
    public static let controlSocketName = "control.sock"

    public static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    public static func configDirectory() throws -> URL {
        let dir = applicationSupport().appendingPathComponent(configDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func socketDirectory() -> URL {
        applicationSupport().appendingPathComponent(socketDirectoryName, isDirectory: true)
    }

    public static func controlSocketURL() -> URL {
        socketDirectory().appendingPathComponent(controlSocketName)
    }
}
