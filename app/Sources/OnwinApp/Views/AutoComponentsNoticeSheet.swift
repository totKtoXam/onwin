import SwiftUI
import OnwinCore

// Sheets of the automatic-components flow (AppModel+AutoComponents.swift), presented by ShellSheets:
//   .d3dmetal  the game uses DirectX 12: «Установить D3DMetal» (Apple ID sign-in in onwin) / «Запустить без него»
//   .failure   the program failed again right after onwin installed what it lacked: what was done + the log

@MainActor
struct AutoComponentsNoticeSheet: View {
    @Environment(AppModel.self) private var model
    let notice: AutoComponentsNotice

    var body: some View {
        Group {
            switch notice {
            case .d3dmetal(let offer): d3dmetal(offer)
            case .failure(let failure): failureView(failure)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    // MARK: D3DMetal

    private func d3dmetal(_ offer: AutoComponentsNotice.D3DMetalOffer) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "macbook", tint: OnwinTheme.accent,
                   title: "«\(offer.programTitle)» лучше работает с D3DMetal",
                   subtitle: offer.reason)

            VStack(alignment: .leading, spacing: 10) {
                step("person.crop.circle", "Понадобится войти со своим Apple ID — прямо в окне onwin, на странице Apple. Подойдёт бесплатная учётная запись.")
                step("arrow.down.circle", "onwin сам скачает Game Porting Toolkit и установит D3DMetal для всех пространств — один раз.")
                step("play.circle", "После этого игра запустится сама.")
            }
            .onwinCard(padding: 14)

            HStack(spacing: 10) {
                Button("Отмена", role: .cancel) {
                    model.autoComponentsNotice = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Запустить без D3DMetal") {
                    model.declineD3DMetalOffer(offer)
                }
                .help("Игра запустится через DXMT или DXVK — некоторые игры на DirectX 12 так не работают")
                Button {
                    model.acceptD3DMetalOffer(offer)
                } label: {
                    Label("Установить D3DMetal", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Failure

    private func failureView(_ failure: AutoComponentsNotice.Failure) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   title: "«\(failure.programTitle)» так и не запустилась",
                   subtitle: "onwin установил то, чего ей не хватало, и запустил её ещё раз, но она снова завершилась с ошибкой (код \(failure.exitStatus)).")

            VStack(alignment: .leading, spacing: 10) {
                if !failure.installed.isEmpty {
                    step("checkmark.seal.fill", "Уже установлено: \(failure.installed.joined(separator: ", ")).")
                }
                if !failure.stillMissing.isEmpty {
                    step("shippingbox", "Журнал всё ещё просит: \(failure.stillMissing.joined(separator: ", ")) — попробуйте поставить вручную на странице пространства.")
                }
                step("rectangle.3.group", "Часто помогает другой режим графики: настройки пространства → «Графика».")
                step("doc.text.magnifyingglass", "Причина обычно видна в журнале запуска — его можно показать специалисту или поискать по строкам с «err:».")
            }
            .onwinCard(padding: 14)

            HStack(spacing: 10) {
                Button("Показать в Finder") {
                    model.revealInFinder(failure.logURL)
                }
                Spacer()
                Button {
                    model.open(failure.logURL)
                } label: {
                    Label("Открыть журнал", systemImage: "doc.text")
                }
                Button("Понятно") {
                    model.autoComponentsNotice = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Parts

    private func header(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(OnwinTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
