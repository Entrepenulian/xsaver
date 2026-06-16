import SwiftUI
import AppKit

// Intent: you just copied an X video link and want it in ~/Downloads with one
// gesture. The panel is a single pane of Liquid Glass floating from the menu bar —
// quiet, tactile, native to macOS. One field, one action surface that morphs through
// finding → downloading → saved. No chrome competing with the two things you touch.
//
// Concentric radius: panel 28, padding 12 → inner controls 16.
// Motion: spring/smooth easing, success morph, one error shake (reduced-motion aware),
// tabular + rolling percentage so the number never reflows the row.

struct DownloadPanel: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var fieldFocused: Bool
    @Namespace private var glass
    @Namespace private var toggle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let innerRadius: CGFloat = 16

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                modeToggle
                urlField
                actionSurface
                if case .failure(let message) = state.phase { errorLine(message) }
            }
            .padding(12)
            .background(quitShortcut)
        }
        .frame(width: 320)
        .animation(.smooth(duration: 0.3), value: state.phase)
        .onAppear {
            state.onPanelAppear()
            fieldFocused = true
        }
        .onDisappear {
            state.onPanelDisappear()
        }
    }

    /// Invisible ⌘Q so the app can still be quit while the panel is focused.
    private var quitShortcut: some View {
        Button("Quit xsaver") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Mode toggle (Video / Audio)

    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(AppState.Mode.allCases, id: \.self) { m in
                let selected = state.mode == m
                Text(m.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.30))
                                .matchedGeometryEffect(id: "segment", in: toggle)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        guard !state.isBusy else { return }
                        withAnimation(.snappy(duration: 0.25)) { state.mode = m }
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .opacity(state.isBusy ? 0.5 : 1)
    }

    // MARK: - URL field

    private var urlField: some View {
        TextField("Paste an X post link", text: $state.urlText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(1...2)
            .focused($fieldFocused)
            .disabled(state.isBusy)
            .onSubmit(state.start)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .rect(cornerRadius: innerRadius))
            .modifier(Shake(animatableData: reduceMotion ? 0 : CGFloat(state.shakeToken)))
            .animation(reduceMotion ? nil : .linear(duration: 0.4), value: state.shakeToken)
    }

    // MARK: - Action surface (one element, four states, morphing glass)

    private var actionSurface: some View {
        let shape = RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
        return content
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(progressFill(shape), alignment: .leading)
            .glassEffect(surfaceGlass, in: shape)
            .glassEffectID("action", in: glass)
            .contentShape(shape)
            .onTapGesture(perform: primaryTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle, .failure:
            label(icon: "arrow.down.to.line", text: "Download", strong: true)
                .opacity(canStart ? 1 : 0.5)
        case .working(let status):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(status).font(.callout.weight(.medium))
            }
        case .downloading(let fraction):
            HStack(spacing: 9) {
                Text("Downloading")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text("\(Int(fraction * 100))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: fraction))
            }
            .padding(.horizontal, 16)
        case .success(let url):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: url)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.pathExtension == "m4a" ? "Saved to Downloads / X-Audio" : "Saved to Downloads")
                        .font(.callout.weight(.semibold))
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
        }
    }

    private func label(icon: String, text: String, strong: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).font(.callout.weight(strong ? .semibold : .regular))
        }
    }

    /// Determinate fill that grows under the glass while downloading.
    @ViewBuilder private func progressFill(_ shape: RoundedRectangle) -> some View {
        if case .downloading(let fraction) = state.phase {
            GeometryReader { geo in
                shape
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(.smooth(duration: 0.25), value: fraction)
            }
        }
    }

    private var surfaceGlass: Glass {
        switch state.phase {
        case .idle, .failure:
            return canStart ? .regular.tint(.accentColor).interactive() : .regular
        case .success:
            return .regular.tint(.green.opacity(0.6)).interactive()
        case .working, .downloading:
            return .regular
        }
    }

    // MARK: - Secondary controls

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    // MARK: - Behavior

    private var canStart: Bool {
        !state.urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func primaryTap() {
        switch state.phase {
        case .idle, .failure:
            state.start()
        case .success(let url):
            state.revealInFinder(url)
        case .working, .downloading:
            break
        }
    }
}

/// One horizontal shake cycle, driven by an incrementing token.
private struct Shake: GeometryEffect {
    var travel: CGFloat = 5
    var cycles: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = travel * sin(animatableData * .pi * cycles)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
