import AppKit
import SwiftUI

/// Carries the ask-before-paste pill's measured ideal height up to the window
/// controller so the panel can grow vertically to fit (never clip the buttons).
struct AskHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Dynamic Island-style pill. Four visual states (recording, transcribing,
/// success, error) plus a hidden state that collapses the surface entirely.
///
/// Visual target: pure-black pill that visually grows from the notch. No
/// material, no gradient — just black plus a subtle drop shadow for depth.
/// Corner radius matches the notch curvature (height / 2).
///
/// Motion philosophy:
///   * appearance: slide down from behind the notch (offset -20 → 0, fade in)
///     over 220 ms spring
///   * equalizer: periodic sin-based motion, calm and smooth
///   * width transitions: 200 ms interpolating spring (slight overshoot)
///   * content cross-fade: 140 ms ease-out
///
/// Reduce Motion: equalizer freezes at 50%, appearance becomes a 120 ms
/// ease-in-out fade with no spring.
struct PillView: View {
    @ObservedObject var model: PillViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Movable pill (v2, design §B/§D.3): the controller installs this so the
    /// escalation gesture can hand off to AppKit's window-server drag
    /// (`OverlayPanel.beginUserDrag()`). Default is a no-op so the view stays
    /// usable in previews / DEBUG harnesses that build `PillView` without a
    /// panel.
    var onDragEscalate: () -> Void = {}

    /// Movable pill (v2): true only between the slop threshold being crossed and
    /// `.onEnded`, so the single `onDragEscalate()` hand-off fires exactly once
    /// per drag. `performDrag` owns the rest of the motion. `@State` because it
    /// is gesture-local (design §D.3). Replaces the v1 `dragStart`/`isDragging`.
    @State private var didEscalate: Bool = false

    /// v1.14: the pill's subtitle (rendered below the capsule during
    /// recording) reads the currently-bound dictation hotkey and frames
    /// it as the **stop** key. The trigger and stop key are the same
    /// shortcut — pressing it again stops the recording and pastes at
    /// the user's cursor.
    @AppStorage("jot.hotkey.toggleRecording.singleKey") private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

    /// Pill surface geometry. Height is tight to the notch strip; corner
    /// radius equals height/2 so the bottom corners hug the notch curvature.
    static let pillHeight: CGFloat = 36
    static let compactPillWidth: CGFloat = 360
    static let expandedPillWidth: CGFloat = 600
    /// Width when streaming partial is visible — matches
    /// `OverlayWindowController.streamingPillWidth`.
    static let streamingPillWidth: CGFloat = 480
    /// Width and total height when the recording pill is expanded into
    /// the multi-line streaming transcript view (tap to expand).
    static let expandedRecordingWidth: CGFloat = 640
    static let expandedRecordingHeight: CGFloat = 240
    /// Width and height of the expanded ask-before-paste pill. Roomy
    /// rounded-rect (not the 36pt capsule) so the in-text context line and the
    /// full, untruncated mapping + button labels all fit on multiple lines.
    static let expandedAskWidth: CGFloat = 520
    static let expandedAskHeight: CGFloat = 150
    static let horizontalContentPadding: CGFloat = 14
    static let contentSpacing: CGFloat = 10
    /// Movable pill (v2): tap-vs-drag slop. A press that releases within this
    /// distance never starts the escalation gesture and falls through to the
    /// inner `.onTapGesture`/`Button`; past it, the drag escalates to
    /// `performDrag`. Matches the v1 4pt threshold (design §B/§D.3).
    static let dragSlop: CGFloat = 4
    static let errorTextMaxWidth: CGFloat =
        expandedPillWidth - (horizontalContentPadding * 2) - (contentSpacing * 2) - 24
    private static var cornerRadius: CGFloat { pillHeight / 2 }

    var body: some View {
        VStack(spacing: 6) {
            pillSurface

            // v1.14: stop-hotkey hint rendered below the pill while
            // recording. Same shortcut as the trigger — pressing it
            // again stops AND pastes at cursor. Hidden in all other
            // states; the layout collapses cleanly via `if` so the
            // pill stays flush to the notch when idle / transcribing.
            if isRecordingState {
                // Prompt-Picker augment path: when the active Rewrite-with-Voice
                // run is parameterized (e.g. Translate), show the picked prompt's
                // hint so the user knows what detail to speak. Sits above the
                // stop-hotkey hint, same below-the-pill subtitle pattern.
                if let hint = model.augmentHint, !hint.isEmpty {
                    augmentHintBanner(hint)
                        .transition(.opacity)
                }
                stopHotkeyHint
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : pillSpring, value: model.state)
    }

    @ViewBuilder
    private var pillSurface: some View {
        ZStack {
            switch model.state {
            case .hidden:
                Color.clear.frame(width: 0, height: 0)
            case .recording(let elapsed, let streamingPartial):
                if model.isPillExpanded {
                    expandedRecordingBody {
                        ExpandedRecordingContent(
                            elapsed: elapsed,
                            streamingPartial: streamingPartial,
                            reduceMotion: reduceMotion
                        )
                    }
                    .onTapGesture { model.togglePillExpanded() }
                } else {
                    // Stable-canvas (v3): bound the compact recording capsule to
                    // its per-state width (360 idle / 480 once a partial lands) —
                    // it grows inside the stationary canvas, matching `capsuleRect`.
                    pillBody(maxWidth: Self.recordingCapsuleMaxWidth(streamingPartial)) {
                        RecordingContent(
                            elapsed: elapsed,
                            streamingPartial: streamingPartial,
                            isStreamingSession: model.isStreamingSessionActive,
                            reduceMotion: reduceMotion
                        )
                    }
                    .onTapGesture { model.togglePillExpanded() }
                }
            case .transcribing:
                pillBody {
                    TranscribingContent(reduceMotion: reduceMotion)
                }
            case .condensing:
                pillBody {
                    CondensingContent(reduceMotion: reduceMotion)
                }
            case .rewriting:
                pillBody {
                    RewritingContent(reduceMotion: reduceMotion)
                }
            case .transforming:
                pillBody {
                    TransformingContent(reduceMotion: reduceMotion)
                }
            case .success(let preview):
                pillBody {
                    SuccessContent(preview: preview)
                }
            case .notice(let message):
                pillBody(maxWidth: PillView.expandedPillWidth) {
                    NoticeContent(message: message)
                }
            case .savedToRecents(let preview):
                pillBody(maxWidth: PillView.expandedPillWidth) {
                    SavedToRecentsContent(
                        preview: preview,
                        onTap: { model.invokeSavedToRecentsTap() }
                    )
                }
            case .error(let message):
                pillBody(maxWidth: PillView.expandedPillWidth) {
                    ErrorContent(message: message)
                }
            case .holdProgress(let progress):
                pillBody {
                    HoldProgressContent(progress: progress, reduceMotion: reduceMotion)
                }
            case .repairingModel(let modelName, let progress, let isError):
                pillBody(maxWidth: PillView.expandedPillWidth) {
                    RepairingContent(modelName: modelName, progress: progress, isError: isError)
                }
                .onTapGesture { model.invokeRepairPillTap() }
            case .askCorrection(let original, let term, let contextBefore, let contextAfter, let applied):
                // Expanded multi-line ask — modeled on the expanded recording
                // body (rounded-rect, roomy), NOT the 36pt capsule. This is the
                // one moment we need the user's input, so we give the context
                // room to breathe.
                expandedAskBody {
                    AskCorrectionContent(
                        original: original,
                        term: term,
                        contextBefore: contextBefore,
                        contextAfter: contextAfter,
                        applied: applied,
                        onConfirm: { model.confirmAsk() },
                        onDismiss: { model.dismissAsk() }
                    )
                }
            }
        }
        // Pin to the top of the hosting window so the pill's top edge lines
        // up with the window/screen top. Extra vertical space in the window
        // (for shadow rendering) lives below the pill.
        .frame(maxWidth: .infinity, alignment: .top)
        // Movable pill (v2, design §B/§D.3): one ESCALATION-ONLY drag gesture at
        // the root pill content level — the same layer that carries each state's
        // `contentShape(...)` + `.onTapGesture`. `minimumDistance: dragSlop` IS
        // the tap-vs-drag slop: a sub-slop press never starts this gesture and
        // falls through to the inner `.onTapGesture` (expand/collapse/repair) /
        // `Button` exactly as before; past the slop it crosses the threshold and
        // hands off to AppKit's window-server drag (`onDragEscalate()` →
        // `OverlayPanel.beginUserDrag()` → `performDrag`). It computes NO offset
        // and never reads `translation` for placement, so there is no
        // coordinate-feedback loop (the v1 ~1/3-distance bug). The window is
        // moved by the window server, 1:1 with the cursor, in EVERY state — the
        // drag layer below the hosting view makes the panel hittable in passive
        // states too. On macOS, the transcript scrolls via the wheel (not
        // click-drag), so dragging the whole expanded surface doesn't fight the
        // ScrollView.
        .gesture(pillDragGesture)
    }

    /// The whole-pill escalation gesture (design §D.3). Its only job is to cross
    /// the slop threshold once and hand off to the window-server drag — it does
    /// NOT compute any offset (that was the v1 feedback-loop bug). `.local`
    /// coordinate space + never reading `translation` for placement → no
    /// coordinate feedback. A quick tap never starts it, so SwiftUI gesture
    /// arbitration delivers the press to the inner `.onTapGesture`/`Button`.
    private var pillDragGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragSlop, coordinateSpace: .local)
            .onChanged { _ in
                guard !didEscalate else { return }
                didEscalate = true   // once per drag; performDrag owns the rest
                onDragEscalate()     // → panel.beginUserDrag() → performDrag(with: currentEvent)
            }
            .onEnded { _ in didEscalate = false }
    }

    /// Stable-canvas (v3): the compact recording capsule's max width — wide
    /// (`streamingPillWidth`) once a non-blank live-preview partial has arrived,
    /// compact (`compactPillWidth`) otherwise. Replaces the old behaviour where
    /// the WINDOW width bounded the capsule's flexible content.
    static func recordingCapsuleMaxWidth(_ streamingPartial: String?) -> CGFloat {
        let hasText = streamingPartial?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return hasText ? streamingPillWidth : compactPillWidth
    }

    private var isRecordingState: Bool {
        if case .recording = model.state { return true }
        return false
    }

    private var stopHotkeyHint: some View {
        // Force the @AppStorage reads to participate in the view's
        // dependency graph so a hotkey rebind from Settings live-updates
        // the pill's subtitle on the next render.
        _ = toggleSingleKey
        _ = toggleTriggerTypeRaw
        // Rewrite-with-Voice captures (the `.rewriteWithVoice` hotkey AND the
        // Prompt-Picker voice-augment) stop on the AI Rewrite-with-Voice
        // binding, not the dictation toggle. The `isRewriteVoiceCapture` flip
        // re-renders this view, so the label resolves to the right action.
        let action: SingleKey.Action = model.isRewriteVoiceCapture ? .rewriteWithVoice : .toggleRecording
        let label = SingleKeyMigration.effectiveBindingLabel(for: action) ?? "your hotkey"
        return HStack(spacing: 6) {
            Text("Press")
                .foregroundStyle(.white.opacity(0.65))
            Text(label)
                .foregroundStyle(.white)
                .fontWeight(.semibold)
            Text("to stop")
                .foregroundStyle(.white.opacity(0.65))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.65))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        )
        .accessibilityLabel("Press \(label) to stop recording and paste at your cursor.")
    }

    /// Subtitle banner shown below the recording pill during a
    /// Prompt-Picker-augmented Rewrite with Voice capture. Tells the user the
    /// per-use detail the picked prompt wants them to speak (e.g. "Say the
    /// target language…"). Same below-the-pill chrome as `stopHotkeyHint`,
    /// with a speech-bubble glyph to read as "say this".
    @ViewBuilder
    private func augmentHintBanner(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.white.opacity(0.65))
            Text(hint)
                .foregroundStyle(.white)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.65))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        )
        .accessibilityLabel(hint)
    }

    private var pillSpring: Animation {
        .interpolatingSpring(stiffness: 260, damping: 22)
    }

    @ViewBuilder
    private func pillBody<Content: View>(
        maxWidth: CGFloat = PillView.compactPillWidth,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Self.contentSpacing) {
            content()
        }
        .padding(.horizontal, Self.horizontalContentPadding)
        .frame(height: Self.pillHeight)
        // Stable-canvas (v3): the capsule no longer derives its width from the
        // window (now a fixed canvas), so bound it HERE per state — at the SAME
        // width the controller's `pillWidth(for:)` / `capsuleRect` report.
        // Otherwise greedy content (Spacer / maxWidth:.infinity) fills the whole
        // canvas and the rendered pill diverges from its drag/hit region (a
        // visually-solid but click-through dead zone). Defaults to the compact
        // width (status pills); wider states (error/notice/recording) pass theirs.
        .frame(maxWidth: maxWidth)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        )
        .contentShape(Capsule(style: .continuous))
        .transition(pillTransition)
    }

    /// Body for the expanded recording view. A taller rounded-rect (not
    /// a Capsule — the aspect ratio would render as a stadium oval) with
    /// the dot/amplitude/timer chrome on top and a scrollable streaming
    /// transcript below.
    @ViewBuilder
    private func expandedRecordingBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(width: Self.expandedRecordingWidth, height: Self.expandedRecordingHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(pillTransition)
    }

    /// Body for the expanded ask-before-paste view. Same dark rounded-rect
    /// chrome as the expanded recording pill, sized to the ask's multi-line
    /// content (context line + mapping line + two full-label buttons). Height
    /// flexes to fit (`minHeight`) so a long context snippet never clips.
    @ViewBuilder
    private func expandedAskBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(width: Self.expandedAskWidth, alignment: .leading)
        .frame(minHeight: Self.expandedAskHeight, alignment: .top)
        // Take the content's IDEAL height (floored at expandedAskHeight) rather
        // than letting the fixed window clip it — a long mapping/context line
        // must push the pill TALLER so the Use/Keep buttons stay on-screen.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
        // Measure that ideal height and hand it to the window controller so the
        // panel grows to fit (see OverlayWindowController.pillSize / the
        // $measuredAskHeight sink). The measured value is content-driven (width
        // is fixed), so it can't feed back into the window height → no loop.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AskHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(AskHeightKey.self) { height in
            model.measuredAskHeight = height
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(pillTransition)
    }

    private var pillTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: 0.12))
        }
        // Slide down from behind the notch — gives the "grows from notch" feel.
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Recording

private struct RecordingContent: View {
    let elapsed: TimeInterval
    let streamingPartial: String?
    /// True when the active recording is running through the streaming
    /// pipeline (driven by `PillViewModel.isStreamingSessionActive`,
    /// which mirrors `StreamingPartialStore.shared.$isActive`). Used to
    /// suppress the wider waveform fallback in the text slot — for a
    /// streaming session that slot is reserved for live partials, even
    /// while the first partial is in flight, so a momentary waveform
    /// flash before the text lands doesn't look like a glitch.
    let isStreamingSession: Bool
    let reduceMotion: Bool

    /// Empty / whitespace-only partials behave as "no partial yet". The
    /// dot + amplitude bar are visible in either case; the middle text
    /// slot just stays empty until the first non-blank partial lands.
    private var trimmedPartial: String? {
        guard let text = streamingPartial else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(color: Color(nsColor: .systemRed), reduceMotion: reduceMotion)
            if let text = trimmedPartial {
                // Streaming WITH text: a compact meter beside the live transcript
                // (the transcript is the primary signal, the meter just confirms
                // the mic is live).
                AmplitudeTrail(reduceMotion: reduceMotion)
                    .frame(width: 56, height: 22)
                // Truncated trailing-fit text — the latest words win
                // when the partial overflows the available width.
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            } else if isStreamingSession {
                // Streaming session, first partial not arrived yet — compact meter
                // + a reserved (empty) text slot so the partial lands here without
                // a waveform flash in between.
                AmplitudeTrail(reduceMotion: reduceMotion)
                    .frame(width: 56, height: 22)
                Spacer(minLength: 0)
            } else {
                // Non-streaming (e.g. the experimental Qwen3 languages — no live
                // preview): a SINGLE waveform spanning the pill is the whole
                // "we're listening" indicator. One meter, not two.
                AmplitudeTrail(reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, maxHeight: 22)
                    .transition(.opacity)
            }
            Text(PillViewModel.formatElapsed(elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .contentTransition(.numericText())
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

/// Expanded recording view: same chrome (dot + amplitude + timer + Jot)
/// in a top header strip, with the full streaming transcript scrollable
/// below. Tap anywhere to collapse. The transcript is split into
/// sentences and the latest line is highlighted in white; older lines
/// are dimmed for visual hierarchy.
private struct ExpandedRecordingContent: View {
    let elapsed: TimeInterval
    let streamingPartial: String?
    let reduceMotion: Bool

    /// The live transcript as one flowing string. We deliberately do NOT split
    /// on sentence punctuation — breaking a new line after every "." read as
    /// choppy/weird. It renders as naturally-wrapping prose; any real paragraph
    /// breaks (\n\n) the transcript already carries are preserved by `Text`.
    private var transcript: String {
        streamingPartial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top strip mirrors the collapsed pill chrome.
            HStack(spacing: 10) {
                PulsingDot(color: Color(nsColor: .systemRed), reduceMotion: reduceMotion)
                AmplitudeTrail(reduceMotion: reduceMotion)
                    .frame(width: 56, height: 22)
                Spacer(minLength: 0)
                Text(PillViewModel.formatElapsed(elapsed))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                AppLabel()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)

            Divider().background(Color.white.opacity(0.15))

            ScrollViewReader { proxy in
                ScrollView {
                    if transcript.isEmpty {
                        Text("Listening…")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                    } else {
                        Text(transcript)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .id("transcript")
                    }
                }
                .onChange(of: streamingPartial ?? "") { _, _ in
                    guard !transcript.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

/// Small "Jot" tag, right-aligned during active states — mirrors the "oto"
/// label in the reference image.
private struct AppLabel: View {
    var body: some View {
        Text("Jot")
            .font(.system(size: 10, weight: .regular))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.5))
    }
}

private struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing && !reduceMotion ? 1.15 : 1.0)
            .animation(
                reduceMotion ? nil :
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

private struct AmplitudeTrail: View {
    @EnvironmentObject private var amp: AmplitudePublisher
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                    .opacity(0.3 + 0.7 * Double(amp.history.last ?? 0))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { _ in
                    Canvas { ctx, size in
                        guard amp.history.count > 1 else { return }
                        let stepX = size.width / CGFloat(amp.history.count - 1)
                        let midY = size.height / 2
                        // Push deflection to the full half-height so loud
                        // syllables hit the top/bottom edge. The sqrt power
                        // curve below lifts quiet phonemes so they don't
                        // collapse to a hairline at the midline.
                        let scale = (size.height / 2) * 0.98
                        var path = Path()
                        for (i, value) in amp.history.enumerated() {
                            let x = CGFloat(i) * stepX
                            // Sqrt power curve: maps 0.1→0.32, 0.3→0.55,
                            // 0.5→0.71, 0.8→0.89. Quiet sounds rise visibly
                            // while loud peaks still saturate near 1.0.
                            let boosted = sqrt(max(CGFloat(value), 0))
                            // Small deterministic phase jitter so silence
                            // still looks alive rather than flatlined.
                            let phase = CGFloat(sin(Double(i) * 0.9)) * 0.6
                            let y = midY - (boosted * scale + phase)
                            if i == 0 { path.move(to: .init(x: x, y: y)) }
                            else { path.addLine(to: .init(x: x, y: y)) }
                        }
                        ctx.stroke(
                            path,
                            with: .color(Color.accentColor),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.6), location: 0),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Transcribing

private struct TranscribingContent: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemBlue))
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Transcribing")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

private struct ThreeDotLoader: View {
    let reduceMotion: Bool
    @State private var phase = 0
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                DispatchQueue.main.async {
                    phase = (phase + 1) % 3
                }
            }
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func opacity(for i: Int) -> Double {
        if reduceMotion { return 0.7 }
        return i == phase ? 1.0 : 0.3
    }
}

// MARK: - Rewriting

private struct RewritingContent: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Rewriting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(pulse && !reduceMotion ? 0.6 : 0.9))
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Condensing (Ask Jot voice input)

/// Shown while the Ask Jot voice-input pipeline is running
/// Rewrite-based condensation on the raw transcript before sending
/// it to the chatbot. Same cadence as `TransformingContent`.
private struct CondensingContent: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Condensing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(pulse && !reduceMotion ? 0.6 : 0.9))
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Transforming

private struct TransformingContent: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemPurple))
                .frame(width: 7, height: 7)
            ThreeDotLoader(reduceMotion: reduceMotion)
            Spacer(minLength: 4)
            Text("Cleaning up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(pulse && !reduceMotion ? 0.6 : 0.9))
                .animation(
                    reduceMotion ? nil :
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
            AppLabel()
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Success

private struct SuccessContent: View {
    let preview: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .systemGreen))
                .frame(width: 7, height: 7)
            Text(preview)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Notice (informational, non-failure)

/// Rendered for `PillState.notice`. Visual chrome is intentionally distinct
/// from `.error`: an `info.circle.fill` glyph in `.secondaryLabel` (not red)
/// so a fallback like "Recorded with system default — AirPods Pro 2 was
/// unavailable." reads as info, not failure.
private struct NoticeContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Text(displayMessage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: PillView.errorTextMaxWidth, alignment: .leading)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }

    private var displayMessage: String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Saved to Recents (post-Esc / post-pill-click affordance)

/// Rendered for `PillState.savedToRecents`. Clickable — tapping opens
/// Recents in the main window so the user can find the recording they
/// just chose not to paste.
private struct SavedToRecentsContent: View {
    let preview: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved to Recents")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: PillView.errorTextMaxWidth, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording saved to Recents. Click to open.")
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Ask before paste (Slice D)

/// Rendered for `PillState.askCorrection`. The live "Did you mean \"<term>\"?"
/// prompt shown while the delivery bridge holds the staged paste. Amber accent
/// dot ("needs your call", distinct from the green success dot). Two REAL
/// buttons so the ask is fully usable without the keyboard (accessibility), plus
/// ⏎ / esc glyph hints that mirror the ask-scoped global shortcuts. Confirm =
/// apply the term; Keep = keep the original word. Either way the bridge delivers
/// exactly once afterward.
private struct AskCorrectionContent: View {
    let original: String
    let term: String
    /// Snippet of the staged text on either side of the in-text word. May be
    /// empty (word at start / end of text); the context line renders only the
    /// pieces that exist.
    let contextBefore: String
    let contextAfter: String
    /// `true` → silent-OOV APPLIED case (term is in the text, original is what
    /// "Keep" reverts to). `false` → common-word BLOCKED near-miss (original is
    /// in the text, term is what "Apply" writes).
    let applied: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The word currently sitting in the text — emphasized in the context line.
    private var inTextWord: String { applied ? term : original }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: amber "needs your call" dot + label + Jot tag.
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                    .frame(width: 7, height: 7)
                Text("Check this word")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                // 10s countdown to auto-accept (matches jot-mobile's keyboard
                // hold-mode card). On depletion the ask pastes the gate's default
                // without the user having to click.
                CountdownRing(seconds: PillViewModel.askLinger, reduceMotion: reduceMotion)
                AppLabel()
            }

            // Context line — the in-text word shown in its actual sentence so
            // the user sees exactly what's being changed.
            contextLine
                .font(.system(size: 14))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Mapping / question line — both words in full, no truncation.
            Text(mappingText)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Two full-label buttons. Confirm applies the term; Keep keeps what
            // was originally said. ⏎ / esc glyphs mirror the ask-scoped shortcuts.
            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    HStack(spacing: 5) {
                        Text("⏎").font(.system(size: 12, weight: .semibold))
                        Text("Use “\(term)”").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous).fill(Color.white.opacity(0.18))
                    )
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(term)")

                Button(action: onDismiss) {
                    HStack(spacing: 5) {
                        Text("esc").font(.system(size: 11, weight: .semibold))
                        Text("Keep “\(original)”").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous).fill(Color.white.opacity(0.09))
                    )
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keep \(original)")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }

    /// Builds `…<before> <inTextWord> <after>…` with the in-text word bolded +
    /// amber so the user can spot it instantly inside the sentence.
    private var contextLine: Text {
        var line = Text("")
        let before = contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = contextAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty {
            line = line + Text(before + " ").foregroundColor(.white.opacity(0.85))
        }
        line = line + Text(inTextWord)
            .fontWeight(.bold)
            .foregroundColor(Color(nsColor: .systemOrange))
        if !after.isEmpty {
            line = line + Text(" " + after).foregroundColor(.white.opacity(0.85))
        }
        return line
    }

    /// Mapping line — full words, no truncation, branch-specific phrasing.
    private var mappingText: String {
        if applied {
            // Silent-OOV: the gate already swapped heard→term; ask to keep it.
            return "Replaced “\(original)” → “\(term)”. Keep it?"
        } else {
            // Common-word near-miss: the gate left the original; offer the term.
            return "You said “\(original)”. Did you mean vocabulary term “\(term)”?"
        }
    }
}

/// A depleting ring that visualizes the ask's auto-accept countdown — a thin arc
/// that sweeps from full to empty over `seconds` (mirrors jot-mobile's keyboard
/// hold-mode `CountdownRing`). Under Reduce Motion it shows a static full ring
/// (no sweep), matching mobile.
private struct CountdownRing: View {
    let seconds: TimeInterval
    let reduceMotion: Bool

    @State private var trim: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(
                    Color(nsColor: .systemOrange).opacity(0.9),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: seconds)) { trim = 0 }
        }
    }
}


// MARK: - Repairing model (startup self-heal)

/// Rendered for `PillState.repairingModel` (design §Phase 3). Persistent —
/// shows download progress while the active transcription model re-downloads
/// after a failed launch integrity probe, or a failure affordance once the
/// heal could not complete. Tapping routes to Settings → Transcription.
private struct RepairingContent: View {
    let modelName: String
    let progress: Double?
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemBlue))
            }
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
                .frame(maxWidth: PillView.errorTextMaxWidth, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityLabel(label + ". Click to open Settings.")
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }

    private var label: String {
        if isError {
            return "Couldn’t download \(modelName) — open Settings"
        }
        if let progress {
            return "Repairing transcription model — downloading \(modelName)… \(Int(progress * 100))%"
        }
        return "Repairing transcription model — downloading \(modelName)…"
    }
}

// MARK: - Error

private struct ErrorContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(displayMessage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: PillView.errorTextMaxWidth, alignment: .leading)
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .help(message)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }

    private var displayMessage: String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Hold progress (Prompt Picker entry)

/// Rendered for `PillState.holdProgress`. Shows a small filled ring on
/// the left (whose stroke completes from 0 → 1 over the hold window),
/// plus the copy "keep holding…". When `reduceMotion` is on the ring
/// is rendered statically at the current progress value.
private struct HoldProgressContent: View {
    let progress: Double
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                    .frame(width: 14, height: 14)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
                    .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30.0), value: progress)
            }
            Text("keep holding…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}
