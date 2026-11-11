import AppKit
import OnwinCore
import SwiftUI
import WebKit

/// Content of `AppleSignInWindow`: the three steps, a status line, Apple's own sign-in page and a
/// small «Открыть в браузере» fallback. The password and the 2FA code are typed on Apple's page;
/// onwin only waits for Apple's session to appear in the app's web data store.
@MainActor
struct AppleSignInView: View {
    @Bindable var state: AppleSignInState
    let onPageLoaded: () -> Void
    let onOpenInBrowser: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AppleSignInWebView(url: AppleDeveloperDownloads.signInURL, onPageLoaded: onPageLoaded)
                .frame(minHeight: 380)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                OnwinSpaceIcon(symbol: "cube.transparent.fill", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Установка D3DMetal")
                        .font(.title2.weight(.semibold))
                    Text("Apple выдаёт Game Porting Toolkit только после входа с Apple ID. Войдите на странице Apple ниже — дальше onwin всё сделает сам.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                AppleSignInStepChip(number: 1, title: "Вход в Apple ID", state: .current)
                stepConnector
                AppleSignInStepChip(number: 2, title: "Загрузка Game Porting Toolkit", state: .upcoming)
                stepConnector
                AppleSignInStepChip(number: 3, title: "Установка D3DMetal", state: .upcoming)
            }
            HStack(spacing: 8) {
                if state.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.isWarning ? "exclamationmark.triangle.fill" : "person.badge.key.fill")
                        .foregroundStyle(state.isWarning ? Color.orange : OnwinTheme.accent)
                }
                Text(state.isChecking ? "Проверяю вход в Apple ID…" : state.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((state.isWarning ? Color.orange : OnwinTheme.accent).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(20)
    }

    private var stepConnector: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 18, height: 1)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Пароль вводится на странице Apple, onwin его не видит и не сохраняет. Вход запоминается, как в Safari, — в следующий раз он не понадобится.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle("Удалить образ после установки", isOn: $state.deleteImageAfterImport)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("По умолчанию скачанный .dmg остаётся в кэше onwin, чтобы переустановка не требовала новой загрузки")
            Button("Открыть в браузере", action: onOpenInBrowser)
                .buttonStyle(.link)
                .font(.caption)
                .help("Скачать Game Porting Toolkit в браузере — onwin подхватит .dmg из «Загрузок»")
            Button("Отмена", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// One step of the install flow in the sign-in header.
@MainActor
struct AppleSignInStepChip: View {
    enum StepState { case done, current, upcoming }
    let number: Int
    let title: String
    let state: StepState

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(state == .upcoming ? Color.primary.opacity(0.12) : OnwinTheme.accent)
                if state == .done {
                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(Color.white)
                } else {
                    Text("\(number)").font(.caption2.bold())
                        .foregroundStyle(state == .upcoming ? Color.secondary : Color.white)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.caption.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
        }
    }
}

/// WKWebView on the app's default (persistent) website data store.
@MainActor
struct AppleSignInWebView: NSViewRepresentable {
    let url: URL
    let onPageLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageLoaded: onPageLoaded) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Apple's sign-in treats a bare WebKit user agent as an unknown browser; present the
        // Safari of this macOS (WKWebView *is* Safari's engine).
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onPageLoaded: () -> Void
        init(onPageLoaded: @escaping () -> Void) { self.onPageLoaded = onPageLoaded }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageLoaded()
        }

        /// https only; the page itself stays on Apple's sites, other links open in the default browser.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased() ?? ""
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if !isMainFrame {
                decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
                return
            }
            let host = url.host?.lowercased() ?? ""
            let isApple = ["apple.com", "cdn-apple.com", "icloud.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            if scheme == "https" && isApple {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }

        /// Links that open a new window (target=_blank) stay in this view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
