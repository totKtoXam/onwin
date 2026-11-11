import AppKit
import SwiftUI
import OnwinCore

// "Игры Steam" on the space page: games the space's Windows Steam has installed
// (steamapps/appmanifest_*.acf in every library of libraryfolders.vdf). They start through Steam
// (steam.exe -applaunch <appid>), so DRM, cloud saves and updates work as on Windows.
// Shown only when the space has Steam.

@MainActor
struct SteamGamesSection: View {
    let space: Space

    @Environment(AppModel.self) private var model
    @State private var steam: SteamInstallation?
    @State private var games: [SteamGame] = []
    @State private var covers: [Int: NSImage] = [:]
    @State private var selectedID: Int?
    @State private var reloadCounter = 0

    var body: some View {
        let running = model.runningPrograms(in: space.id)
        let runningTitles = Set(running.map(\.title))
        Group {
            if let steam {
                VStack(alignment: .leading, spacing: 12) {
                    header(steam)
                    if games.isEmpty {
                        emptyCard
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 180), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(games) { game in
                                card(game, isRunning: runningTitles.contains(game.name))
                            }
                        }
                    }
                }
            }
        }
        // Re-scan when something starts or stops (Steam finishing a download usually comes with that),
        // when the program list is refreshed and on demand.
        .task(id: "\(space.id)-\(running.count)-\(model.programs(in: space).count)-\(reloadCounter)") {
            await scan()
        }
    }

    private func header(_ steam: SteamInstallation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Игры Steam")
                    .font(.title3.weight(.semibold))
                Text("Запускаются через Steam этого пространства. Двойной щелчок — играть.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                reloadCounter += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Обновить список игр")
            Button {
                model.openSteam(in: space)
            } label: {
                Label("Открыть Steam", systemImage: "gamecontroller")
            }
            .disabled(!model.hasEngine)
        }
    }

    private var emptyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("В Steam пока нет установленных игр")
                    .font(.headline)
                Text("Откройте Steam, войдите в аккаунт и установите игру из библиотеки — она появится здесь.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .onwinCard(padding: 14)
    }

    private func card(_ game: SteamGame, isRunning: Bool) -> some View {
        SteamGameCard(game: game, cover: covers[game.appID], space: space, isSelected: selectedID == game.appID,
                      isRunning: isRunning,
                      onSelect: { selectedID = game.appID },
                      onRun: { play(game) })
            .contextMenu {
                Button {
                    play(game)
                } label: {
                    Label("Играть", systemImage: "play.fill")
                }
                .disabled(!model.hasEngine)
                Button {
                    ProgramDialogs.shared.request = .runWithOptions(space.id, .steamGame(game))
                } label: {
                    Label("Запустить с параметрами…", systemImage: "slider.horizontal.below.rectangle")
                }
                .disabled(!model.hasEngine)
                Divider()
                Button {
                    model.revealInFinder(OnwinPaths.exists(game.installDirectory) ? game.installDirectory : game.library)
                } label: {
                    Label("Показать папку игры", systemImage: "folder")
                }
                Button {
                    model.openSteamURL(Steam.validateURL(game.appID),
                                       title: String(localized: "Steam — проверка «\(game.name)»"), in: space)
                } label: {
                    Label("Проверить целостность файлов", systemImage: "checkmark.shield")
                }
                Button {
                    model.openSteamURL(Steam.storeURL(game.appID), title: String(localized: "Steam — «\(game.name)»"), in: space)
                } label: {
                    Label("Страница в магазине Steam", systemImage: "cart")
                }
                Divider()
                Button(role: .destructive) {
                    model.openSteamURL(Steam.uninstallURL(game.appID),
                                       title: String(localized: "Steam — удаление «\(game.name)»"), in: space)
                } label: {
                    Label("Удалить через Steam…", systemImage: "trash")
                }
            }
    }

    private func play(_ game: SteamGame) {
        selectedID = game.appID
        model.launchSteamGame(game, in: space)
    }

    private func scan() async {
        let current = model.space(id: space.id) ?? space
        let result = await Task.detached { () -> (SteamInstallation?, [SteamGame], [Int: URL]) in
            guard let steam = Steam.installation(in: current) else { return (nil, [], [:]) }
            let games = Steam.games(of: steam, in: current)
            var art: [Int: URL] = [:]
            for g in games { if let url = Steam.artwork(for: g, steam: steam) { art[g.appID] = url } }
            return (steam, games, art)
        }.value
        steam = result.0
        games = result.1
        var images: [Int: NSImage] = [:]
        for (id, url) in result.2 {
            if let cached = covers[id] { images[id] = cached } else if let image = NSImage(contentsOf: url) { images[id] = image }
        }
        covers = images
    }
}

@MainActor
private struct SteamGameCard: View {
    let game: SteamGame
    let cover: NSImage?
    /// For the fallback icon (Steam's shortcut icon / the game exe's icon) when there is no cover.
    let space: Space
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 9) {
            coverView
            Text(verbatim: game.name)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .frame(height: 34, alignment: .top)
            HStack(spacing: 5) {
                if isRunning {
                    OnwinRunningDot(size: 6)
                    Text("Запущено")
                } else if !game.isFullyInstalled {
                    Image(systemName: "arrow.down.circle")
                    Text("Загружается")
                } else if game.isBusy {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Нужно обновление")
                } else {
                    Text(verbatim: "Steam")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                .fill(isSelected ? OnwinTheme.accent.opacity(0.14)
                                 : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? OnwinTheme.accent : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if (isHovering || isSelected) && game.isFullyInstalled {
                Button(action: onRun) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, OnwinTheme.accent)
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("Играть")
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: OnwinTheme.cornerRadius, style: .continuous))
        .onTapGesture(count: 2, perform: onRun)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("\(game.name)\nSteam App \(game.appID) — двойной щелчок запускает через Steam")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Играть")) { onRun() }
    }

    @ViewBuilder
    private var coverView: some View {
        if let cover {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.2), radius: 3, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.indigo, Color.indigo.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 96)
                .overlay(
                    AppIconView(subject: .steamGame(appID: game.appID, space: space, style: .icon), size: 52) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                )
        }
    }
}
