import AppKit
import Foundation

extension LauncherBuilder {
    /// Launchpad icon of a Steam game's program (its exe lies in `steamapps/common/<game>`), nil for other
    /// programs. Order: Steam's square shortcut icon (`steam/games/<hash>.ico`), the exe icon when it is
    /// at least 128 px, the library cover / header, the small community icon; the exe icon of any size is
    /// left to the regular path (`iconImage`).
    static func steamLauncherImage(for program: SpaceProgram, in space: Space) -> NSImage? {
        guard let exe = program.executable, let found = Steam.game(containing: exe, in: space) else { return nil }
        let art = Steam.art(for: found.game.appID, steam: found.steam, space: space)
        if let ico = art.clientIcon, let image = IconExtractor.icon(for: ico) { return image }
        if let image = IconExtractor.icon(for: exe), max(image.size.width, image.size.height) >= 128 { return image }
        for url in [art.cover, art.header, art.icon].compactMap({ $0 }) {
            if let image = AppIcons.image(at: url) { return image }
        }
        return nil
    }
}
