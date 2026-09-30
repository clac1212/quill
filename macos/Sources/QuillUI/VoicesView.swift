import SwiftUI

/// The naming window's content: pick a session, play each voice, type a name.
public struct VoicesView: View {
    @ObservedObject var model: VoicesModel

    public init(model: VoicesModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sessions.isEmpty {
                Text("No transcribed session has voices yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Session", selection: $model.selected) {
                    ForEach(model.sessions) { session in
                        Text(session.id + (session.unnamed > 0 ? " · \(session.unnamed) unnamed" : ""))
                            .tag(Optional(session.id))
                    }
                }
                List(model.voices) { voice in
                    row(voice)
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 300)
    }

    private func row(_ voice: VoiceItem) -> some View {
        HStack {
            Button {
                model.togglePlay(voice)
            } label: {
                Image(systemName: model.playing == voice.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            Text("voice \(voice.id)")
                .monospacedDigit()
                .foregroundStyle(voice.ignored ? .secondary : .primary)
                .frame(width: 64, alignment: .leading)
            TextField("Name", text: draft(voice.id))
                .onSubmit { model.save(voice) }
            Menu {
                ForEach(model.knownNames, id: \.self) { name in
                    Button(name) {
                        model.drafts[voice.id] = name
                        model.save(voice)
                    }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.knownNames.isEmpty)
            Button("Save") { model.save(voice) }
                .disabled(!model.hasChanges(voice))
            Button(voice.ignored ? "Unignore" : "Ignore") { model.toggleIgnored(voice) }
                .disabled(voice.name != nil)
        }
    }

    private func draft(_ id: Int) -> Binding<String> {
        Binding(
            get: { model.drafts[id] ?? "" },
            set: { model.drafts[id] = $0 }
        )
    }
}

#if DEBUG
/// In-memory sessions for the canvas: a named voice, unnamed ones, an
/// ignored one. Naming and ignoring work; playback has no audio behind it and
/// shows an error — expected.
@MainActor
final class PreviewVoicesStore: VoicesStore {
    private var data: [String: [VoiceItem]]
    private var names: Set<String>

    init(empty: Bool = false) {
        let sample = URL(fileURLWithPath: "/dev/null")
        func voice(_ id: Int, _ name: String?, ignored: Bool = false) -> VoiceItem {
            VoiceItem(id: id, name: name, ignored: ignored, sampleURL: sample, sampleStart: 12, sampleEnd: 18)
        }
        data =
            empty
            ? [:]
            : [
                "2026.09.30-0753": [voice(1, "César"), voice(2, nil), voice(3, nil), voice(4, nil, ignored: true)],
                "2026.09.29-1400": [voice(1, "César"), voice(2, "Justine")],
            ]
        names = empty ? [] : ["César", "Justine", "Blandine"]
    }

    func sessions() -> [VoiceSession] {
        data.keys.sorted(by: >).map { id in
            VoiceSession(id: id, unnamed: data[id]!.filter { $0.name == nil && !$0.ignored }.count)
        }
    }

    func voices(in session: String) throws -> [VoiceItem] { data[session] ?? [] }

    func knownNames() -> [String] { names.sorted() }

    func setName(_ name: String?, voice: Int, session: String) throws {
        update(voice, in: session) { VoiceItem(id: $0.id, name: name, ignored: false, sampleURL: $0.sampleURL, sampleStart: $0.sampleStart, sampleEnd: $0.sampleEnd) }
        if let name { names.insert(name) }
    }

    func setIgnored(_ ignored: Bool, voice: Int, session: String) throws {
        update(voice, in: session) { VoiceItem(id: $0.id, name: $0.name, ignored: ignored, sampleURL: $0.sampleURL, sampleStart: $0.sampleStart, sampleEnd: $0.sampleEnd) }
    }

    private func update(_ id: Int, in session: String, _ change: (VoiceItem) -> VoiceItem) {
        data[session] = data[session]?.map { $0.id == id ? change($0) : $0 }
    }
}

@MainActor
private func previewModel(empty: Bool = false) -> VoicesModel {
    let model = VoicesModel(store: PreviewVoicesStore(empty: empty))
    model.reload()
    return model
}

#Preview("Voices") {
    VoicesView(model: previewModel())
        .frame(width: 560, height: 360)
}

#Preview("No sessions") {
    VoicesView(model: previewModel(empty: true))
        .frame(width: 560, height: 360)
}
#endif
