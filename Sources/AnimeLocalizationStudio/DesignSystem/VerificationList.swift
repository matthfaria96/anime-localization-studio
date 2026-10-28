import MediaKit
import SwiftUI

/// The integrity checks of a written MKV, passed or failed, one per line.
struct VerificationList: View {
    let report: VerificationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.checks) { check in
                Label {
                    Text("\(Text(check.title).font(.caption.weight(.medium))) \(Text("— \(check.detail)").font(.caption).foregroundStyle(.secondary))")
                } icon: {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? Theme.translated : Theme.failure)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
