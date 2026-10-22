import SwiftUI

/// A provider or refinement error shown whole: wrapped over as many lines as it needs and
/// selectable, so the user can read it and copy it into a support request. Never one clipped line.
struct ErrorMessageText: View {
    let message: String
    var size: CGFloat = 11

    var body: some View {
        Text(message)
            .font(.system(size: size))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
