import SwiftUI

/// Shows entries that could not be uploaded yet and will be retried automatically.
struct PendingQueueView: View {
    let queue: TreatmentQueue

    var body: some View {
        if !queue.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Warteschlange (\(queue.items.count))", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    if queue.isFlushing {
                        ProgressView()
                    } else {
                        Button("Jetzt senden") {
                            Task { await queue.flush() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }

                Text("Diese Einträge wurden noch nicht übertragen. Sie werden automatisch mit ihrer ursprünglichen Uhrzeit nachgeholt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(queue.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(item.displayText, systemImage: item.isGlucose ? "drop.fill" : "fork.knife")
                                .font(.body.weight(.semibold))
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let err = item.lastError {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            queue.remove(item.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Eintrag verwerfen")
                        .disabled(queue.isFlushing)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1.5)
            )
        }
    }
}
