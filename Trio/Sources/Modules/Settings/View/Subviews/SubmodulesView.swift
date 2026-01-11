import SwiftUI

struct SubmodulesView: View {
    let buildDetails: BuildDetails

    var body: some View {
        List {
            Section(header: Text("Trio")) {
                KeyValueRow(key: buildDetails.trioBranch, value: buildDetails.trioCommitSHA)
            }
            Section(header: Text("Submodules")) {
                ForEach(buildDetails.submodules.sorted(by: { $0.key < $1.key }), id: \.key) { name, info in
                    KeyValueRow(key: name, value: info.commitSHA)
                }
            }
            if !buildDetails.patches.isEmpty {
                Section(header: Text("Patches")) {
                    ForEach(Array(buildDetails.patches.enumerated()), id: \.offset) { _, patch in
                        PatchRow(
                            name: patch.name,
                            subject: patch.subject,
                            sha: patch.fromSHA,
                            date: patch.date
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Submodules")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key)
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct PatchRow: View {
    let name: String
    let subject: String
    let sha: String
    let date: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundColor(.primary)
                if !subject.isEmpty {
                    Text(subject)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(sha)
                    .foregroundColor(.secondary)
                if !date.isEmpty {
                    Text(date)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
