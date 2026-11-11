import AppKit
import SwiftUI
import OnwinCore

// The original application logos in the UI (OnwinCore/AppIcons.swift resolves them):
//
//   AppIconView(subject: .recipe(recipe, spaces: model.spaces), symbol: recipe.symbol, size: 46)
//   AppIconView(subject: .component(component), symbol: component.symbol, size: 40)
//   AppIconView(subject: …, size: 38) { custom placeholder }
//   SpaceIconView(space: space, size: 24)      icon of the space's main / pinned program
//
// The placeholder (the SF Symbol tile onwin always had) is shown until the icon is resolved off the
// main thread, and stays when there is none. A resolved icon from the memory cache is shown on the
// first frame. Opaque square art (covers, store icons) is clipped to the rounded tile; transparent
// Windows icons are drawn inside a neutral tile.

@MainActor
struct AppIconView<Placeholder: View>: View {
    let subject: AppIconSubject?
    var size: CGFloat
    let placeholder: Placeholder

    @State private var image: NSImage?

    init(subject: AppIconSubject?, size: CGFloat = 28, @ViewBuilder placeholder: () -> Placeholder) {
        self.subject = subject
        self.size = size
        self.placeholder = placeholder()
        _image = State(initialValue: subject.flatMap { AppIcons.cachedImage(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                AppIconTile(image: image, size: size)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: subject) {
            guard let subject else { image = nil; return }
            let url = await AppIcons.resolve(subject)
            guard !Task.isCancelled else { return }
            image = url.flatMap { AppIcons.image(at: $0) }
        }
    }
}

extension AppIconView where Placeholder == OnwinSpaceIcon {
    /// With the regular teal SF Symbol tile as placeholder.
    init(subject: AppIconSubject?, symbol: String, size: CGFloat = 28) {
        self.init(subject: subject, size: size) {
            OnwinSpaceIcon(symbol: symbol, size: size)
        }
    }
}

/// A resolved icon in onwin's rounded tile.
@MainActor
struct AppIconTile: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if AppIconTile.isOpaque(image) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: innerSide, height: innerSide)
                    )
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.15), radius: size * 0.06, y: size * 0.03)
        .accessibilityHidden(true)
    }

    /// Windows icons fill ~80% of the tile; tiny ones (32 px) are not blown up as much.
    private var innerSide: CGFloat {
        let pixels = max(image.size.width, image.size.height)
        return pixels > 0 && pixels < 64 ? size * 0.62 : size * 0.8
    }

    private static let opacity: NSCache<NSImage, NSNumber> = {
        let cache = NSCache<NSImage, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    static func isOpaque(_ image: NSImage) -> Bool {
        if let known = opacity.object(forKey: image) { return known.boolValue }
        let value = AppIcons.isOpaqueTile(image)
        opacity.setObject(NSNumber(value: value), forKey: image)
        return value
    }
}

/// The icon of a space: its main (catalog recipe / pinned) program's own icon, else the SF Symbol tile.
@MainActor
struct SpaceIconView: View {
    let space: Space
    var size: CGFloat = 28

    var body: some View {
        let programs = AppModel.shared.programs(in: space)
        AppIconView(subject: .space(space, programs: programs), symbol: space.onwinSymbol, size: size)
    }
}
