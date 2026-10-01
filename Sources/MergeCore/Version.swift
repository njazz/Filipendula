import Foundation

public enum FilipendulaInfo {
    /// Single source of truth for the app/CLI version. `scripts/version.sh` reads this line;
    /// keep `MARKETING_VERSION` in project.yml in sync (CI checks it).
    public static let version = "0.1.5"
}
