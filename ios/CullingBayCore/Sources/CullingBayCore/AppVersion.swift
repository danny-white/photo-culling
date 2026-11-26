import Foundation

/// What Settings shows about the build that is running: the build number `ios/build-ipa.sh`
/// stamps in (the git commit count, the same number as on the builds page at `/m/ios/`) and the
/// commit it was built from.
public enum AppVersion {
    /// "Build 154 · 975f562". A build made in Xcode without the script has build "1" and no
    /// commit, so it reads "Development build". No build number at all gives nil.
    public static func label(build: String?, revision: String?) -> String? {
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        let revision = revision?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !build.isEmpty else { return nil }
        if build == "1" && revision.isEmpty { return "Development build" }
        return revision.isEmpty ? "Build \(build)" : "Build \(build) · \(revision)"
    }

    /// The same, from an app bundle's Info.plist: `CFBundleVersion` and `CBGitRevision`.
    public static func label(info: [String: Any]?) -> String? {
        label(build: info?["CFBundleVersion"] as? String, revision: info?["CBGitRevision"] as? String)
    }
}
