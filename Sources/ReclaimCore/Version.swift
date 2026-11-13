import Foundation

public enum ReclaimInfo {
    /// Single source of truth for the version. Release tags must match (`v` + this).
    public static let version = "0.6.0"

    public static let repositoryURL = URL(string: "https://github.com/Unfield/Reclaim")!
    public static let releasesURL = URL(string: "https://github.com/Unfield/Reclaim/releases")!
    public static let issuesURL = URL(string: "https://github.com/Unfield/Reclaim/issues/new/choose")!
}
