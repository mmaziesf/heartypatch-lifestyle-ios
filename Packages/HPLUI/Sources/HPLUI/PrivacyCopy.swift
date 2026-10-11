import Foundation
import HPLCore

/// Settings › Privacy & your data. Must stay true to what the code does (FTC Act §5: no "anonymous", no "HIPAA").
/// Mirrored in docs/privacy-policy.md and the App Privacy answers in docs/testflight-checklist.md.
public enum PrivacyCopy {
    public static let points = [
        "Everything is stored on this iPhone in an encrypted, file-protected store. There is no account and no server.",
        "Apple Health is read-only. Only per-day totals are kept; raw samples stay in Health.",
        "Lab reports you import stay in the app's protected folder. Values are shown as printed; we don't interpret them.",
        "Glasses meals arrive as signed files from apps you pair. Photos are not imported.",
        "No analytics, ads or tracking SDKs. Nothing is sold or shared.",
        "Cloud analysis is off unless you turn it on. In this version it runs on this iPhone, so nothing leaves the device.",
        "iCloud or computer backups of your iPhone can include this app's data; encrypted backups protect it.",
    ]

    public static let exportExplainer = "One JSON file with everything stored here: consents, daily totals, labs, meals, notes, experiments " +
        "and cloud history. Report files and pairing secrets are not included. Keep it somewhere private."

    public static let deleteTitle = "Delete all data?"
    public static let deleteMessage = "This removes everything HP Lifestyle stored on this iPhone: daily totals, lab results and report files, " +
        "meals, glasses pairings, notes and experiments, cloud history, consents, settings and reminders. " +
        "Data in Apple Health is not touched. This can't be undone."
    public static let deleteHealthAccess = "To also remove HP Lifestyle's access to Apple Health, open Settings › Privacy & Security › Health › HP Lifestyle."

    public static func wipeSummary(_ r: WipeReport) -> String {
        if r.verified { return "All data deleted and checked: nothing is left." }
        let failed = r.items.filter { !$0.isClean }.map(\.name).joined(separator: ", ")
        return "Some data couldn't be deleted (\(failed)). Try again, or delete the app to remove everything."
    }

    public static func scopeLabel(_ s: ConsentScope) -> String {
        switch s {
        case .disclaimer: "Not-medical-advice notice"
        case .healthkit: "Apple Health"
        case .labs: "Lab imports"
        case .glasses: "Glasses meals"
        case .cloudAnalysis: "Cloud analysis"
        case .mediaRetention: "Photo retention"
        }
    }
}
