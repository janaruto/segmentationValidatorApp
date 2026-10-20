import SwiftUI

/// "True" on "Moving detected?": how is the user moving, and since when?
struct MovingAnswerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let answer: MovingAnswer

    @State private var type: MovementType?
    @State private var start: Date

    init(answer: MovingAnswer) {
        self.answer = answer
        _start = State(initialValue: answer.start)
        // Walking and cycling are reliable enough to pre-select; vehicles are only highlighted.
        _type = State(initialValue: answer.activity?.suggestedMovementType.flatMap { $0.isMoving ? $0 : nil })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answer.prompt.question(stationaryDistance: model.settings.stationaryDistance))
                                .font(.subheadline)
                            if let activity = answer.activity {
                                Text(L10n.format("Motion sensor: %@", activity.displayName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "location.fill")
                            .foregroundStyle(Color.brand)
                    }
                }

                if let running = model.book.running {
                    Section {
                        HStack(spacing: 10) {
                            TypeIcon(type: running.type, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(running.type.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(L10n.format("Still running – it will end at %@", Formatting.time(start)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Previous segment")
                    }
                }

                Section {
                    MovementTypeGrid(
                        selection: $type,
                        highlighted: answer.activity == .automotive ? MovementType.vehicles : [],
                        types: MovementType.allCases.filter(\.isMoving)
                    )
                } header: {
                    Text("How are you moving?")
                }

                Section {
                    DatePicker("Start", selection: $start, in: ...Date(), displayedComponents: .hourAndMinute)
                } footer: {
                    Text("Estimated from your location points. Adjust it if needed.")
                }

                Section {
                    Button(role: .destructive) {
                        model.answer(answer.prompt, with: false)
                        dismiss()
                    } label: {
                        Label("False – I am not moving", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(answer.prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        if let type, model.startMoving(type, at: start, answering: answer.prompt) {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(type == nil)
                }
            }
            .alert(model.alert?.title ?? "", isPresented: alertBinding, presenting: model.alert) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { isPresented in
                if !isPresented {
                    model.alert = nil
                }
            }
        )
    }
}
