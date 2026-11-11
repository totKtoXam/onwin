import Foundation
import OnwinCore

extension Bundle {
    /// onwinctl's translations: `String(localized: "…", bundle: .onwinctl)`. onwinctl follows the
    /// system language (and the language chosen in onwin's settings when run from inside Onwin.app).
    static let onwinctl = OnwinResources.bundle(named: "onwinctl")
}
