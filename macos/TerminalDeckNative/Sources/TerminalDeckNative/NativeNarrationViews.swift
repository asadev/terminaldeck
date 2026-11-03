import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Live narration's views (lane NARR): the "Talk while recording" control beside
/// Record, the caption strip under the phone while recording, and the screens list on
/// the finished recording's card.

// MARK: - Record's options

/// The small chevron attached to Record: "Talk while recording" (checkmark, remembered),
/// who writes the words, and the language. Part of the Record button, not a second recorder.
struct NativeNarrationRecordOptions: View {
    @Bindable var settings: NativeNarrationSettings
    var disabled = false

    var body: some View {
        Menu { items } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .help(!settings.hasMicrophone ? "Recording options — this Mac has no microphone, so Record makes a plain video"
              : settings.talk ? "Recording options — Talk while recording is on: your words are written per screen as you talk"
                              : "Recording options — Talk while recording is off: a plain video")
        .accessibilityLabel("Recording options")
    }

    /// The options themselves; the phone bar shows them on a right-click of its one Record icon (Asad 10 Oct).
    @ViewBuilder var items: some View {
            // No microphone on this Mac (a Mac mini): the switch is greyed and says why; Record makes a plain video.
            Toggle(settings.hasMicrophone ? "Talk while recording" : "Talk while recording — no microphone on this Mac",
                   isOn: Binding(get: { settings.talking }, set: { settings.talk = $0 }))
                .disabled(!settings.hasMicrophone)
            Divider()
            Section("Your words are written by") {
                Picker("Your words are written by", selection: $settings.engine) {
                    Text("This Mac (private, free)").tag(NativeNarrationSettings.Engine.mac)
                    Text(settings.keyProvider.map { "\($0) (your voice key, more accurate)" } ?? "Your voice key: none saved")
                        .tag(NativeNarrationSettings.Engine.key)
                        .selectionDisabled(settings.keyProvider == nil)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(!settings.talking)
            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text(settings.languageName("")).tag("")
                    ForEach(settings.languages, id: \.identifier) { locale in
                        Text(settings.languageName(locale.identifier)).tag(locale.identifier)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(!settings.talking)
        .accessibilityValue(!settings.hasMicrophone ? "No microphone on this Mac" : settings.talk ? "Talk while recording on" : "Talk while recording off")
        .onAppear { settings.load() }
    }
}

// MARK: - The caption strip

/// Under the phone while recording with talk on: the screen his words go to now
/// ("Listing details · 0:12") and his words appearing as he speaks.
struct NativeNarrationStrip: View {
    let narration: NativeNarration
    /// Fixed time for an offscreen picture; nil uses the clock.
    var at: Date?

    static let height: CGFloat = 58

    var body: some View {
        Group {
            if let at { strip(at) } else {
                TimelineView(.periodic(from: narration.startedAt ?? .now, by: 1)) { context in strip(context.date) }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live words")
    }

    private func strip(_ date: Date) -> some View {
        let timeline = narration.timeline
        let seconds = narration.startedAt.map { date.timeIntervalSince($0) } ?? 0
        let caption = timeline.caption(maxCharacters: 160)
        return HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                if let id = timeline.current?.id, let thumb = narration.thumbnails[id] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .frame(height: 34).clipShape(.rect(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeline.tag(now: seconds))
                        .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                    // Only until he says something on this screen.
                    if let current = timeline.current, timeline.words(in: current).isEmpty, current.edited == nil {
                        Text("Your words go here").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.red.opacity(0.10), in: .rect(cornerRadius: 8))
            .help("The screen your words are attached to now, and how long it has been on show")
            .fixedSize()

            Group {
                if !narration.status.isEmpty {
                    Text(narration.status).foregroundStyle(.secondary)
                } else if caption.isEmpty {
                    Text(narration.waiting ? "Writing…" : "Start talking — your words appear here.").foregroundStyle(.secondary)
                } else {
                    Text(caption + (narration.waiting ? " …" : ""))
                }
            }
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
        .padding(.horizontal, 12)
    }
}

// MARK: - The screens on the card

/// One row per screen: its picture, name, time, and his words (editable before Send).
struct NativeNarrationScreens: View {
    let narration: NativeNarration

    var body: some View {
        let timeline = narration.timeline
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(timeline.segments) { segment in
                    row(segment, timeline: timeline)
                    if segment.id != timeline.segments.last?.id { Divider() }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ segment: NarrationSegment, timeline: NarrationTimeline) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let thumb = narration.thumbnails[segment.id] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .overlay(Image(systemName: "iphone").foregroundStyle(.secondary))
                }
            }
            .frame(width: 44, height: 90)
            .clipShape(.rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator.opacity(0.6)))
            .onTapGesture(count: 2) {
                if let path = segment.keyframe { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            .help(segment.keyframe.map { "The picture sent for this screen: \($0)" } ?? "No picture of this screen")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(segment.id)").font(.caption.weight(.semibold)).monospacedDigit()
                        .frame(width: 18, height: 18).background(.quaternary, in: .circle)
                    Text(segment.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(NarrationTimeline.clock(segment.start))–\(NarrationTimeline.clock(segment.end ?? segment.start))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                NativeNarrationWordsEditor(
                    text: Binding(get: { narration.timeline.text(of: segment.id) },
                                  set: { narration.edit(segment.id, text: $0) }),
                    placeholder: "Nothing said on this screen — type what to say")
                    .accessibilityLabel("Your words on screen \(segment.id), \(segment.title)")
            }
        }
    }
}

/// His words for one screen: wraps to fit, grows with the text (up to a few lines), editable.
struct NativeNarrationWordsEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the box to the words.
            Text((text.isEmpty ? placeholder : text) + " ")
                .font(.callout)
                .lineLimit(1...6)
                .padding(.horizontal, 5).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .scrollDisabled(false)
            if text.isEmpty {
                Text(placeholder).font(.callout).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.6)))
    }
}
