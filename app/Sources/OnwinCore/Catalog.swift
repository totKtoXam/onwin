import Foundation

/// An installable add-on for a space (winetricks calls these "verbs").
///
/// A component is a list of `downloads` (each verified: pinned SHA-256 where the file never changes,
/// a PE / cabinet header check for redirecting links such as aka.ms) and a list of `actions` that
/// `ComponentInstaller` executes in order: run an installer, pull DLLs out of Microsoft cabinets
/// with cabextract, copy them into system32/syswow64, write registry values, register fonts...
/// After the actions, `dllOverrides` are stored in the space config.
///
/// `satisfiesImports` (glob patterns over lower-case DLL names, without ".dll") is what
/// `DependencyAdvisor` uses to map a game's PE imports and Wine log errors to components.
public struct Component: Identifiable, Hashable, Sendable {
    /// One installer file run by an app recipe (`AppRecipe.installer`).
    public struct Step: Hashable, Sendable {
        public var url: URL
        public var fileName: String
        public var arguments: [String]
        /// Run the file directly (exe) or with msiexec (msi).
        public init(_ url: String, fileName: String? = nil, arguments: [String] = []) {
            self.url = URL(string: url)!
            self.fileName = fileName ?? self.url.lastPathComponent
            self.arguments = arguments
        }
    }

    /// Where a component lives: inside one space, or shared by every space (D3DMetal).
    public enum Kind: String, Hashable, Sendable {
        case space
        case global
    }

    public enum Category: String, CaseIterable, Hashable, Sendable {
        case graphics = "Графика и DirectX"
        case runtimes = "Библиотеки Visual C++"
        case dotnet = ".NET"
        case other = "Прочее"

        public var symbol: String {
            switch self {
            case .graphics: return "cpu"
            case .runtimes: return "shippingbox"
            case .dotnet: return "chevron.left.forwardslash.chevron.right"
            case .other: return "square.stack.3d.up"
            }
        }
    }

    /// A file to download into the cache (`~/Library/Caches/onwin/Downloads`).
    public struct Download: Hashable, Sendable {
        public enum Verification: Hashable, Sendable {
            /// The file is pinned: its SHA-256 must match (lower-case hex).
            case sha256(String)
            /// The link redirects to whatever Microsoft publishes now (aka.ms): we can only check
            /// that it is a non-empty Windows PE file ("MZ" + "PE\0\0").
            case portableExecutable
            /// Unpinned Microsoft cabinet: non-empty and starts with "MSCF".
            case cabinet
        }

        public var url: URL
        /// Unique name in the download cache (several redistributables are all called vcredist_x86.exe).
        public var fileName: String
        public var verification: Verification
        /// Approximate size for the UI.
        public var approximateBytes: Int64

        public init(_ url: String, fileName: String? = nil, _ verification: Verification, bytes: Int64) {
            self.url = URL(string: url)!
            self.fileName = fileName ?? self.url.lastPathComponent
            self.verification = verification
            self.approximateBytes = bytes
        }
    }

    /// Target directory of copied files.
    public enum Destination: String, Hashable, Sendable {
        /// 64-bit DLLs: `windows/system32` of a 64-bit space (skipped in a 32-bit space).
        case dll64
        /// 32-bit DLLs: `windows/syswow64` (or `system32` of a 32-bit space).
        case dll32
        /// `windows/Fonts`
        case fonts
    }

    /// Files taken out of a Microsoft cabinet (or a self-extracting exe that is one) with cabextract.
    public struct Extraction: Hashable, Sendable {
        /// `Download.fileName` of the archive.
        public var source: String
        /// When non-empty, the archive contains further cabinets: these patterns select them
        /// (cabextract -F) and `files` are then extracted from each of them.
        public var cabinets: [String]
        /// Patterns (lower case, cabextract -L) of the files to take.
        public var files: [String]
        public var destination: Destination
        /// Exact renames (lower-case extracted name → final name).
        public var renames: [String: String]
        /// Suffixes cut from extracted names ("msvcp140.dll_x86" → "msvcp140.dll").
        public var stripSuffixes: [String]
        /// When true, finding nothing is not an error (the installer already did the main job).
        public var optional: Bool

        public init(from source: String, cabinets: [String] = [], files: [String], to destination: Destination,
                    renames: [String: String] = [:], stripSuffixes: [String] = [], optional: Bool = false) {
            self.source = source; self.cabinets = cabinets; self.files = files; self.destination = destination
            self.renames = renames; self.stripSuffixes = stripSuffixes; self.optional = optional
        }
    }

    public struct RegistryValue: Hashable, Sendable {
        public enum Value: Hashable, Sendable { case string(String), dword(UInt32) }
        public var key: String
        public var name: String
        public var value: Value
        public init(_ key: String, _ name: String, _ value: Value) { self.key = key; self.name = name; self.value = value }
    }

    public struct Font: Hashable, Sendable {
        public var file: String
        public var name: String
        public init(_ file: String, _ name: String) { self.file = file; self.name = name }
    }

    public enum Action: Hashable, Sendable {
        /// Run a downloaded exe / msi with arguments and extra DLL overrides for this run.
        case run(String, arguments: [String], overrides: [String: String] = [:])
        case extract(Extraction)
        case registry([RegistryValue])
        /// Fonts already copied into windows/Fonts: register them in the registry.
        case registerFonts([Font])
        /// regsvr32 for files (glob patterns) in a destination directory; failures are logged only.
        case registerServers([String], in: Destination)
        /// Uninstall Wine Mono (real .NET refuses to install next to it).
        case removeWineMono
        /// Temporarily switch the space's Windows version (some installers require an old one).
        case setWindowsVersion(WindowsVersion)
        /// Back to the version from the space config.
        case restoreWindowsVersion
    }

    public var id: String
    public var name: String
    public var summary: String
    public var category: Category
    public var kind: Kind
    public var symbol: String
    public var downloads: [Download]
    public var actions: [Action]
    public var dllOverrides: [String: String]
    /// Human-readable list of what the component puts into the space (cards, tooltips).
    public var providesDLLs: [String]
    /// Glob patterns over lower-case DLL names without ".dll" that this component satisfies.
    public var satisfiesImports: [String]
    /// Components installed first.
    public var requires: [String]
    /// Components this one supersedes (removed from `installedComponents` after installing).
    public var replaces: [String]
    /// Earlier ids of the same component (configs written by older onwin versions).
    public var legacyIDs: [String]
    /// Shown in the catalog (prerequisite-only components are hidden).
    public var isListed: Bool
    public var notes: String

    public init(id: String, name: String, summary: String, category: Category, kind: Kind = .space,
                symbol: String = "puzzlepiece.extension.fill",
                downloads: [Download] = [], actions: [Action] = [], dllOverrides: [String: String] = [:],
                providesDLLs: [String] = [], satisfiesImports: [String] = [], requires: [String] = [],
                replaces: [String] = [], legacyIDs: [String] = [], isListed: Bool = true, notes: String = "") {
        self.id = id; self.name = name; self.summary = summary; self.category = category; self.kind = kind
        self.symbol = symbol; self.downloads = downloads; self.actions = actions; self.dllOverrides = dllOverrides
        self.providesDLLs = providesDLLs; self.satisfiesImports = satisfiesImports; self.requires = requires
        self.replaces = replaces; self.legacyIDs = legacyIDs; self.isListed = isListed; self.notes = notes
    }

    /// Total download size, including required components.
    public var approximateDownloadBytes: Int64 {
        downloads.reduce(0) { $0 + $1.approximateBytes }
            + requires.compactMap { Catalog.component($0) }.reduce(0) { $0 + $1.approximateDownloadBytes }
    }

    /// "≈ 95 МБ"
    public var sizeDescription: String {
        let bytes = approximateDownloadBytes
        if bytes <= 0 { return kind == .global ? "с сайта Apple" : "—" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return "≈ 1 МБ" }
        if mb < 10 { return String(format: "≈ %.1f МБ", mb).replacingOccurrences(of: ".", with: ",") }
        return "≈ \(Int(mb.rounded())) МБ"
    }

    public func isInstalled(in config: SpaceConfig) -> Bool {
        if kind == .global { return id == Catalog.d3dmetalID && GraphicsSupport.isD3DMetalInstalled }
        return config.installedComponents.contains(id) || legacyIDs.contains { config.installedComponents.contains($0) }
    }

    /// True when `dll` (any case, with or without ".dll") is one this component provides.
    public func satisfies(dll: String) -> Bool {
        let name = Catalog.normalizedDLLName(dll)
        return satisfiesImports.contains { Glob.matches($0, name) }
    }
}

/// A recipe for installing a Windows application: installer, space settings, components, launch path.
public struct AppRecipe: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case launchers = "Игровые лаунчеры"
        case runtimes = "Компоненты"
        case utilities = "Утилиты"
        /// Recipes the user wrote (UserRecipes.swift); not part of the built-in list.
        case user = "Мои приложения"
    }

    public var id: String
    public var name: String
    public var summary: String
    public var category: Category
    public var installer: Component.Step?
    public var windowsVersion: WindowsVersion
    public var backend: GraphicsBackend
    public var components: [String]
    /// Windows path of the program to launch after installation.
    public var launchPath: String?
    public var launchArguments: [String]
    public var spaceName: String
    public var notes: String
    public var symbol: String
    /// Steam game: after the Steam client is in the space, `steam://install/<id>` is opened (Steam.swift).
    /// Optional so recipe files without it keep loading.
    public var steamAppID: Int? = nil
    /// Environment of the pinned program (user recipes, `UserRecipe.environment`).
    public var launchEnvironment: [String: String] = [:]
    /// Official high-resolution icon on the vendor's own site (AppIcons.swift); used until the program
    /// itself (its exe icon) or its cached installer can provide one. nil → exe / installer / SF Symbol.
    public var iconURL: URL? = nil
}

public enum Catalog {
    // Must match Wine 11.0 (CrossOver 26.3 sources): dlls/appwiz.cpl/addons.c, MONO_VERSION / GECKO_VERSION.
    public static let wineMonoVersion = "10.4.1"
    public static let wineGeckoVersion = "2.47.4"
    static let wineMonoSHA256 = "071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23"
    static let wineGeckoX86SHA256 = "26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"
    static let wineGeckoX64SHA256 = "e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"

    public static let d3dmetalID = "d3dmetal"
    /// Apple's download page for the Game Porting Toolkit (needs a free Apple developer account).
    public static let gameportingToolkitURL = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    static let directxJun2010 = "directx_Jun2010_redist.exe"

    // MARK: Components

    public static let components: [Component] = [
        // Steam's own setting "Enable GPU accelerated rendering in web views" (Steam → Settings → Interface),
        // stored by Steam in HKCU\Software\Valve\Steam\GPUAccelWebViews. Off: the CEF web views render in
        // software, which together with the steamwebhelper switches in CompatDB keeps the window from
        // staying black under Wine on macOS (onwin test, Apple M5 / macOS 26.5, 11.11.2026).
        Component(id: "steam-tweaks", name: "Настройки Steam для Mac",
                  summary: "Программная отрисовка окон Steam: без чёрного окна и с работающим встроенным браузером",
                  category: .other, symbol: "gamecontroller",
                  actions: [
                    .registry([
                        .init(#"HKEY_CURRENT_USER\Software\Valve\Steam"#, "GPUAccelWebViews", .dword(0)),
                    ]),
                  ],
                  isListed: false),
        // ---- Graphics --------------------------------------------------------------------------
        Component(
            id: d3dmetalID, name: "D3DMetal (Game Porting Toolkit)",
            summary: "DirectX 11/12 → Metal от Apple: нужен играм на DirectX 12. onwin сам скачает его с сайта Apple после входа с Apple ID",
            category: .graphics, kind: .global, symbol: "macbook",
            providesDLLs: ["d3d12", "d3d11", "dxgi", "nvngx (MetalFX)"],
            satisfiesImports: ["d3d12", "d3d12core"],
            notes: "Один раз на все пространства. Нужна бесплатная учётная запись Apple Developer."),
        Component(
            id: "directx-jun2010", name: "DirectX (июнь 2010)",
            summary: "Оригинальные D3DX 9/10/11, XInput 1.3, XAudio2 и XACT из последнего DirectX End-User Runtime",
            category: .graphics, symbol: "gamecontroller.fill",
            downloads: [.init("https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
                              .sha256("053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"), bytes: 100_275_120)],
            actions: directxActions,
            dllOverrides: directxOverrides,
            providesDLLs: ["d3dx9_24…43", "d3dx10_33…43", "d3dx11_42/43", "d3dcompiler_43", "xinput1_1…1_3",
                           "xaudio2_0…2_7", "x3daudio1_*", "xapofx1_*", "xactengine*"],
            satisfiesImports: ["d3dx9_*", "d3dx10_*", "d3dx11_*", "d3dcompiler_43", "xinput1_1", "xinput1_2", "xinput1_3",
                               "xaudio2_[0-7]", "x3daudio1_*", "xapofx1_*", "xactengine*"],
            notes: "64-битные XAudio/XACT не ставятся: в Wine они ломают звук (как в winetricks)."),
        Component(
            id: "d3dcompiler_47", name: "D3DCompiler 47",
            summary: "Компилятор шейдеров HLSL от Microsoft (из Windows SDK): нужен многим играм на Unity и Unreal",
            category: .graphics, symbol: "function",
            downloads: [.init("https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/2630bae9681db6a9f6722366f47d055c.cab",
                              fileName: "d3dcompiler_47-sdk-x86-2630bae9681db6a9f6722366f47d055c.cab", .cabinet, bytes: 1_488_323),
                        .init("https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/61d57a7a82309cd161a854a6f4619e52.cab",
                              fileName: "d3dcompiler_47-sdk-x64-61d57a7a82309cd161a854a6f4619e52.cab", .cabinet, bytes: 1_776_364)],
            actions: [
                .extract(.init(from: "d3dcompiler_47-sdk-x86-2630bae9681db6a9f6722366f47d055c.cab",
                               files: ["fila319f706acfa16d6707473ebf29bdc7f"], to: .dll32,
                               renames: ["fila319f706acfa16d6707473ebf29bdc7f": "d3dcompiler_47.dll"])),
                .extract(.init(from: "d3dcompiler_47-sdk-x64-61d57a7a82309cd161a854a6f4619e52.cab",
                               files: ["fil3585cb2ea5db13cc0838f8d06b5c9679"], to: .dll64,
                               renames: ["fil3585cb2ea5db13cc0838f8d06b5c9679": "d3dcompiler_47.dll"])),
            ],
            dllOverrides: ["d3dcompiler_47": "n"],
            providesDLLs: ["d3dcompiler_47 (32 и 64 бит)"],
            satisfiesImports: ["d3dcompiler_47"]),

        // ---- Visual C++ ------------------------------------------------------------------------
        Component(
            id: "vcrun2026", name: "Visual C++ v14 (2015–2026)",
            summary: "Последние библиотеки Microsoft Visual C++ 14.x — нужны почти всем современным играм и лаунчерам",
            category: .runtimes, symbol: "shippingbox.fill",
            downloads: [.init("https://aka.ms/vc14/vc_redist.x86.exe", fileName: "vc_redist_v14.x86.exe", .portableExecutable, bytes: 6_919_464),
                        .init("https://aka.ms/vc14/vc_redist.x64.exe", fileName: "vc_redist_v14.x64.exe", .portableExecutable, bytes: 18_863_624)],
            actions: [
                .run("vc_redist_v14.x86.exe", arguments: ["/install", "/quiet", "/norestart"]),
                // Setup refuses to replace msvcp140 / msvcp140_2 because Wine's builtins have a higher
                // version number (https://bugs.winehq.org/show_bug.cgi?id=57518): copy them by hand.
                .extract(.init(from: "vc_redist_v14.x86.exe", cabinets: ["a*"],
                               files: ["msvcp140.dll_x86", "msvcp140_2.dll_x86"], to: .dll32,
                               stripSuffixes: ["_x86"], optional: true)),
                .run("vc_redist_v14.x64.exe", arguments: ["/install", "/quiet", "/norestart"]),
                .extract(.init(from: "vc_redist_v14.x64.exe", cabinets: ["a*"],
                               files: ["msvcp140.dll_amd64", "msvcp140_2.dll_amd64", "vcruntime140_1.dll_amd64"], to: .dll64,
                               stripSuffixes: ["_amd64"], optional: true)),
            ],
            dllOverrides: overrides(["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                                     "msvcp140_codecvt_ids", "vcamp140", "vccorlib140", "vcomp140", "vcruntime140",
                                     "vcruntime140_1"], "n,b"),
            providesDLLs: ["msvcp140*", "vcruntime140", "vcruntime140_1", "concrt140", "vcomp140", "mfc140*"],
            satisfiesImports: ["msvcp140*", "vcruntime140*", "concrt140", "vcomp140", "vcamp140", "vccorlib140",
                               "mfc140*", "mfcm140*"],
            legacyIDs: ["vcrun2022"]),
        vcRedist(year: "2013", version: "12.0",
                 x86: ("https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x86.exe",
                       "89f4e593ea5541d1c53f983923124f9fd061a1c0c967339109e375c661573c17", 6_510_544),
                 x64: ("https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe",
                       "20e2645b7cd5873b1fa3462b99a665ac8d6e14aae83ded9d875fea35ffdd7d7e", 7_201_032),
                 dlls: ["atl120", "msvcp120", "msvcr120", "vcomp120"], extra: ["mfc120*"]),
        vcRedist(year: "2012", version: "11.0",
                 x86: ("https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe",
                       "b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386", 6_554_576),
                 x64: ("https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe",
                       "681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064", 7_186_992),
                 dlls: ["atl110", "msvcp110", "msvcr110", "vcomp110"], extra: ["mfc110*"]),
        vcRedist(year: "2010", version: "10.0",
                 x86: ("https://download.microsoft.com/download/5/B/C/5BC5DBB3-652D-4DCE-B14A-475AB85EEF6E/vcredist_x86.exe",
                       "31d32fa39d52cac9a765a43660431f7a127eee784b54b2f5e2af3e2b763a1af8", 5_076_456),
                 x64: ("https://download.microsoft.com/download/A/8/0/A80747C3-41BD-45DF-B505-E9710D2744E0/vcredist_x64.exe",
                       "2fddbc3aaaab784c16bc673c3bae5f80929d5b372810dbc28649283566d33255", 5_677_032),
                 dlls: ["atl100", "msvcp100", "msvcr100", "vcomp100"], extra: ["mfc100*"]),
        vcRedist(year: "2008", version: "9.0",
                 x86: ("https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe",
                       "8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92", 4_216_840),
                 x64: ("https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe",
                       "c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654", 5_211_080),
                 dlls: ["atl90", "msvcm90", "msvcp90", "msvcr90", "vcomp90"], extra: ["mfc90*"]),

        // ---- .NET ------------------------------------------------------------------------------
        Component(
            id: "wine-mono", name: "Wine Mono \(wineMonoVersion)",
            summary: "Открытая замена .NET Framework для программ на C#/.NET — ставится быстро, подходит большинству",
            category: .dotnet, symbol: "chevron.left.forwardslash.chevron.right",
            downloads: [.init("https://dl.winehq.org/wine/wine-mono/\(wineMonoVersion)/wine-mono-\(wineMonoVersion)-x86.msi",
                              .sha256(wineMonoSHA256), bytes: 85_504_000)],
            actions: [.run("wine-mono-\(wineMonoVersion)-x86.msi", arguments: ["/qn"])],
            providesDLLs: ["mscoree", "mscorlib", "System.*"],
            satisfiesImports: ["mscoree"],
            notes: "Версия соответствует Wine 11.0."),
        Component(
            id: "dotnet48", name: ".NET Framework 4.8",
            summary: "Настоящий .NET от Microsoft для программ, которым не хватает Wine Mono (установка долгая)",
            category: .dotnet, symbol: "chevron.left.forwardslash.chevron.right",
            downloads: [.init("https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe",
                              .sha256("95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"), bytes: 72_721_568)],
            actions: [
                .removeWineMono,
                .setWindowsVersion(.win7),
                .run("ndp48-x86-x64-allos-enu.exe", arguments: ["/sfxlang:1027", "/q", "/norestart"], overrides: ["fusion": "b"]),
                .restoreWindowsVersion,
            ],
            dllOverrides: ["mscoree": "n"],
            providesDLLs: ["mscoree", "mscorlib 4.8", "WPF", "WinForms"],
            satisfiesImports: ["mscoree"],
            requires: ["dotnet40"],
            replaces: ["wine-mono"],
            notes: "Wine Mono будет удалён. Версия 4.8.1 в Wine зависает при установке, поэтому — 4.8."),
        Component(
            id: "dotnet40", name: ".NET Framework 4.0",
            summary: "Нужен установщику .NET 4.8",
            category: .dotnet, symbol: "chevron.left.forwardslash.chevron.right",
            downloads: [.init("https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe",
                              .sha256("65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"), bytes: 50_449_456)],
            actions: [
                .removeWineMono,
                .setWindowsVersion(.winxp),
                .run("dotNetFx40_Full_x86_x64.exe", arguments: ["/q", "/c:install.exe /q"], overrides: ["fusion": "b"]),
                .registry([
                    .init(#"HKEY_LOCAL_MACHINE\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "Install", .dword(1)),
                    .init(#"HKEY_LOCAL_MACHINE\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "Version", .string("4.0.30319")),
                    .init(#"HKEY_LOCAL_MACHINE\Software\Microsoft\.NETFramework"#, "OnlyUseLatestCLR", .dword(1)),
                    .init(#"HKEY_LOCAL_MACHINE\Software\Wow6432Node\.NETFramework"#, "OnlyUseLatestCLR", .dword(1)),
                ]),
                .restoreWindowsVersion,
            ],
            dllOverrides: ["mscoree": "n"],
            providesDLLs: ["mscoree", "mscorlib 4.0"],
            replaces: ["wine-mono"],
            isListed: false),

        // ---- Other -----------------------------------------------------------------------------
        Component(
            id: "wine-gecko", name: "Wine Gecko \(wineGeckoVersion)",
            summary: "Движок HTML для встроенных окон браузера: лаунчеры, справка, окна входа",
            category: .other, symbol: "globe",
            downloads: [.init("https://dl.winehq.org/wine/wine-gecko/\(wineGeckoVersion)/wine-gecko-\(wineGeckoVersion)-x86_64.msi",
                              .sha256(wineGeckoX64SHA256), bytes: 53_898_752),
                        .init("https://dl.winehq.org/wine/wine-gecko/\(wineGeckoVersion)/wine-gecko-\(wineGeckoVersion)-x86.msi",
                              .sha256(wineGeckoX86SHA256), bytes: 55_187_968)],
            actions: [.run("wine-gecko-\(wineGeckoVersion)-x86_64.msi", arguments: ["/qn"]),
                      .run("wine-gecko-\(wineGeckoVersion)-x86.msi", arguments: ["/qn"])],
            providesDLLs: ["mshtml (Gecko)"],
            satisfiesImports: ["mshtml"],
            notes: "Версия соответствует Wine 11.0."),
        Component(
            id: "corefonts", name: "Шрифты Microsoft Core Fonts",
            summary: "Arial, Times New Roman, Courier New, Verdana, Georgia и другие — для правильного текста в играх и программах",
            category: .other, symbol: "textformat",
            downloads: coreFontFiles.map { .init("https://github.com/pushcx/corefonts/raw/master/\($0.0).exe",
                                                 fileName: "corefonts-\($0.0).exe", .sha256($0.1), bytes: $0.2) },
            actions: coreFontFiles.map { .extract(.init(from: "corefonts-\($0.0).exe", files: ["*.ttf"], to: .fonts)) }
                + [.registerFonts(coreFonts)],
            providesDLLs: ["Arial", "Times New Roman", "Courier New", "Verdana", "Georgia", "Trebuchet MS",
                           "Comic Sans MS", "Impact", "Andale Mono", "Webdings"]),
        Component(
            id: "physx", name: "NVIDIA PhysX (System Software 9.23)",
            summary: "Старый PhysX для игр 2008–2015 годов, которые ищут PhysXLoader.dll",
            category: .other, symbol: "atom",
            downloads: [.init("https://us.download.nvidia.com/Windows/9.23.1019/PhysX_9.23.1019_SystemSoftware.exe",
                              .sha256("9b42b84e881769d681e09f62a1b51532616b2e6a2d5d99d0ccae6eb5fbbc208c"), bytes: 29_417_888)],
            actions: [.run("PhysX_9.23.1019_SystemSoftware.exe", arguments: ["/s"])],
            providesDLLs: ["PhysXLoader", "PhysXCore", "PhysXCooking", "PhysXDevice", "cudart"],
            satisfiesImports: ["physxloader", "physxloader64", "physxcore", "physxcore64", "physxcooking", "physxcooking64",
                               "physxdevice", "physxdevice64", "nxcooking", "nxcharacter", "physxextensions"],
            notes: "Расчёт идёт на процессоре: видеокарт NVIDIA в Mac нет."),
    ]

    /// Built-in recipes; `Catalog.apps` (UserRecipes.swift) adds the user's own ones.
    public static let builtinApps: [AppRecipe] = [
        AppRecipe(id: "steam", name: "Steam", summary: "Магазин и лаунчер игр Valve",
                  category: .launchers,
                  installer: .init("https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe", arguments: ["/S"]),
                  windowsVersion: .win10, backend: .auto, components: ["steam-tweaks"],
                  // Software-rendered Steam UI: CEF's GPU path fails under Wine on macOS (black window:
                  // ANGLE gets only GLES 2 on WineD3D and EGL_BAD_ALLOC on DXMT). Games are unaffected.
                  launchPath: #"C:\Program Files (x86)\Steam\steam.exe"#,
                  launchArguments: ["-cef-disable-gpu", "-cef-disable-gpu-compositing"],
                  spaceName: "Steam", notes: "После установки Steam обновится и попросит войти в аккаунт.",
                  symbol: "gamecontroller",
                  // Valve's 512×512 Steam logo on its store CDN (steamstatic.com, the installer's host too).
                  iconURL: URL(string: "https://store.akamai.steamstatic.com/public/shared/images/responsive/share_steam_logo.png")),
        AppRecipe(id: "epic", name: "Epic Games Launcher", summary: "Лаунчер Epic Games Store",
                  category: .launchers,
                  installer: .init("https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi",
                                   arguments: ["/qn"]),
                  windowsVersion: .win10, backend: .auto, components: ["vcrun2026"],
                  launchPath: #"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#,
                  // Public Epic launcher switches (used by Lutris' and other Wine front ends' Epic scripts):
                  // OpenGL UI renderer, skip the bundled VC++ prerequisite installer.
                  launchArguments: ["-opengl", "-SkipBuildPatchPrereq"],
                  spaceName: "Epic Games", notes: "", symbol: "bolt.horizontal"),
        AppRecipe(id: "gog", name: "GOG Galaxy", summary: "Лаунчер GOG.com",
                  category: .launchers,
                  installer: .init("https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe", arguments: []),
                  windowsVersion: .win10, backend: .auto, components: [],
                  launchPath: #"C:\Program Files (x86)\GOG Galaxy\GalaxyClient.exe"#, launchArguments: [],
                  spaceName: "GOG Galaxy", notes: "", symbol: "circle.hexagongrid",
                  iconURL: URL(string: "https://www.gog.com/apple-touch-icon-180x180.png")),
        AppRecipe(id: "battlenet", name: "Battle.net", summary: "Лаунчер Blizzard",
                  category: .launchers,
                  installer: .init("https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live",
                                   fileName: "Battle.net-Setup.exe", arguments: []),
                  windowsVersion: .win10, backend: .d3dmetal, components: [],
                  launchPath: #"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#, launchArguments: [],
                  spaceName: "Battle.net", notes: "", symbol: "shield",
                  // 196×196 app icon referenced by download.battle.net (Blizzard's own asset CDN).
                  iconURL: URL(string: "https://d2zsxgsqjmrnrw.cloudfront.net/images/favicon-196x196.c3a4cd54fdaeec566e96c37dba35cbca5eccba52.png")),
    ]

    /// Components shown in catalogs (prerequisite-only ones are hidden).
    public static var listedComponents: [Component] { components.filter(\.isListed) }

    /// Finds a component by id, also by an id used by older onwin versions ("vcrun2022").
    public static func component(_ id: String) -> Component? {
        components.first { $0.id == id } ?? components.first { $0.legacyIDs.contains(id) }
    }

    public static func app(_ id: String) -> AppRecipe? { apps.first { $0.id == id } }

    /// Components satisfying an imported DLL, best first (catalog order).
    public static func components(satisfying dll: String) -> [Component] {
        components.filter { $0.satisfies(dll: dll) }
    }

    /// "D3DX9_43.DLL" → "d3dx9_43"
    public static func normalizedDLLName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = n.lastIndex(where: { $0 == "\\" || $0 == "/" }) { n = String(n[n.index(after: slash)...]) }
        if n.hasSuffix(".dll") { n.removeLast(4) }
        return n
    }

    // MARK: Builders

    static func overrides(_ dlls: [String], _ mode: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: dlls.map { ($0, mode) })
    }

    private static func vcRedist(year: String, version: String,
                                 x86: (String, String, Int64), x64: (String, String, Int64),
                                 dlls: [String], extra: [String]) -> Component {
        let f86 = "vcredist\(year)_x86.exe", f64 = "vcredist\(year)_x64.exe"
        return Component(
            id: "vcrun\(year)", name: "Visual C++ \(year) (\(version))",
            summary: "Библиотеки Visual C++ \(year) для игр того времени (\(dlls.filter { $0.hasPrefix("msvc") }.joined(separator: ", ")))",
            category: .runtimes, symbol: "shippingbox",
            downloads: [.init(x86.0, fileName: f86, .sha256(x86.1), bytes: x86.2),
                        .init(x64.0, fileName: f64, .sha256(x64.1), bytes: x64.2)],
            actions: [.run(f86, arguments: ["/q"]), .run(f64, arguments: ["/q"])],
            dllOverrides: overrides(dlls, "n,b"),
            providesDLLs: dlls,
            satisfiesImports: dlls + extra)
    }

    private static let directxCab = directxJun2010

    /// Same selection as winetricks d3dx9 / d3dx10 / d3dx11_43 / d3dcompiler_43 / xinput / xact.
    private static let directxActions: [Component.Action] = {
        var list: [Component.Action] = []
        func both(_ cabPattern: String, _ files: [String]) {
            list.append(.extract(.init(from: directxCab, cabinets: ["*\(cabPattern)*x86*"], files: files, to: .dll32)))
            list.append(.extract(.init(from: directxCab, cabinets: ["*\(cabPattern)*x64*"], files: files, to: .dll64)))
        }
        both("d3dx9", ["d3dx9*.dll"])
        both("d3dx10", ["d3dx10*.dll"])
        both("d3dx11", ["d3dx11*.dll"])
        both("d3dcompiler_43", ["d3dcompiler_43.dll"])
        both("_xinput_", ["xinput*.dll"])
        // 64-bit XACT / XAudio break sound in Wine (https://bugs.winehq.org/show_bug.cgi?id=41618): 32-bit only.
        list.append(.extract(.init(from: directxCab, cabinets: ["*_xact_*x86*", "*_x3daudio_*x86*", "*_xaudio_*x86*"],
                                   files: ["xactengine*.dll", "xaudio*.dll", "x3daudio*.dll", "xapofx*.dll"], to: .dll32)))
        list.append(.registerServers(["xactengine*.dll", "xaudio2_[0-7].dll"], in: .dll32))
        return list
    }()

    private static let directxOverrides: [String: String] = {
        var names: [String] = []
        names += (24...43).map { "d3dx9_\($0)" }
        names += (33...43).map { "d3dx10_\($0)" }
        names += ["d3dx11_42", "d3dx11_43", "d3dcompiler_43", "xinput1_1", "xinput1_2", "xinput1_3"]
        names += (0...7).map { "xaudio2_\($0)" }
        names += (0...7).map { "x3daudio1_\($0)" }
        names += (1...5).map { "xapofx1_\($0)" }
        names += (0...10).map { "xactengine2_\($0)" }
        names += (0...7).map { "xactengine3_\($0)" }
        return overrides(names, "n,b")
    }()

    /// winetricks corefonts sources (mirror of the original Microsoft "Core fonts for the Web" files).
    private static let coreFontFiles: [(String, String, Int64)] = [
        ("andale32", "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970", 198_384),
        ("arial32", "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6", 554_208),
        ("arialb32", "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8", 168_176),
        ("comic32", "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e", 246_008),
        ("courie32", "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384", 646_368),
        ("georgi32", "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301", 392_440),
        ("impact32", "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb", 173_288),
        ("times32", "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab", 661_728),
        ("trebuc32", "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9", 357_200),
        ("verdan32", "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96", 351_992),
        ("webdin32", "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a", 185_072),
    ]

    private static let coreFonts: [Component.Font] = [
        .init("andalemo.ttf", "Andale Mono"),
        .init("arialbd.ttf", "Arial Bold"), .init("arialbi.ttf", "Arial Bold Italic"),
        .init("ariali.ttf", "Arial Italic"), .init("arial.ttf", "Arial"), .init("ariblk.ttf", "Arial Black"),
        .init("comicbd.ttf", "Comic Sans MS Bold"), .init("comic.ttf", "Comic Sans MS"),
        .init("courbd.ttf", "Courier New Bold"), .init("courbi.ttf", "Courier New Bold Italic"),
        .init("couri.ttf", "Courier New Italic"), .init("cour.ttf", "Courier New"),
        .init("georgiab.ttf", "Georgia Bold"), .init("georgiai.ttf", "Georgia Italic"),
        .init("georgia.ttf", "Georgia"), .init("georgiaz.ttf", "Georgia Bold Italic"),
        .init("impact.ttf", "Impact"),
        .init("timesbd.ttf", "Times New Roman Bold"), .init("timesbi.ttf", "Times New Roman Bold Italic"),
        .init("timesi.ttf", "Times New Roman Italic"), .init("times.ttf", "Times New Roman"),
        .init("trebucbd.ttf", "Trebuchet MS Bold"), .init("trebucbi.ttf", "Trebuchet MS Bold Italic"),
        .init("trebucit.ttf", "Trebuchet MS Italic"), .init("trebuc.ttf", "Trebuchet MS"),
        .init("verdanab.ttf", "Verdana Bold"), .init("verdanai.ttf", "Verdana Italic"),
        .init("verdana.ttf", "Verdana"), .init("verdanaz.ttf", "Verdana Bold Italic"),
        .init("webdings.ttf", "Webdings"),
    ]
}

/// fnmatch(3)-style matching (`*`, `?`, `[...]`), case-insensitive.
public enum Glob {
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }
}

extension Component.Action {
    /// One line in Russian, for `onwinctl component-info` and tooltips.
    public var summary: String {
        switch self {
        case .run(let file, let arguments, let overrides):
            let extra = overrides.isEmpty ? "" : " (WINEDLLOVERRIDES " + overrides.map { "\($0.key)=\($0.value)" }.joined(separator: ";") + ")"
            return "запустить \(file) \(arguments.joined(separator: " "))\(extra)"
        case .extract(let e):
            let via = e.cabinets.isEmpty ? "" : " через вложенные \(e.cabinets.joined(separator: ", "))"
            return "достать \(e.files.joined(separator: ", ")) из \(e.source)\(via) → \(e.destination.rawValue)\(e.optional ? " (если есть)" : "")"
        case .registry(let values):
            return "записать в реестр: " + values.map { "\($0.key)\\\($0.name)" }.joined(separator: ", ")
        case .registerFonts(let fonts):
            return "зарегистрировать шрифты (\(fonts.count))"
        case .registerServers(let patterns, let destination):
            return "regsvr32 \(patterns.joined(separator: " ")) в \(destination.rawValue)"
        case .removeWineMono:
            return "удалить Wine Mono"
        case .setWindowsVersion(let v):
            return "временно включить \(v.displayName)"
        case .restoreWindowsVersion:
            return "вернуть версию Windows пространства"
        }
    }
}
