import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// What is dragged inside the window: images from the grid, or a project from the sidebar. One type
/// to decode, but each kind travels under its own content type, so a target that does not take a kind
/// never validates it: no highlight and no badge for a project onto a project or images onto a client.
enum SidebarDrag: Codable, Transferable, Sendable {
    case images([String])
    case project(String)

    enum Kind {
        case images, project
        /// What a drag of this kind carries, and so what a target that takes it lists.
        var contentType: UTType { self == .images ? .json : .plainText }
    }

    var kind: Kind {
        switch self {
        case .images: return .images
        case .project: return .project
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: Kind.images.contentType)
            .exportingCondition { $0.kind == .images }
        CodableRepresentation(contentType: Kind.project.contentType)
            .exportingCondition { $0.kind == .project }
    }
}

enum DragModifiers {
    /// ⌥ held (macOS): a drop of images moves them rather than adds them.
    static var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
}

/// A sidebar row as a drop target: it highlights while a drag is over it and proposes `.copy` (the
/// copy badge) for an add, `.move` when ⌥ is held or the target only ever moves.
struct SidebarDropDelegate: DropDelegate {
    let key: String
    /// The only kind of drag this target takes; any other is not validated.
    let accepts: SidebarDrag.Kind
    @Binding var targeted: String?
    /// True for a target whose drop is always a move (a project onto a client).
    let alwaysMove: Bool
    let handle: @MainActor @Sendable (SidebarDrag, _ optionHeld: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [accepts.contentType]) }

    func dropEntered(info: DropInfo) { targeted = key }

    func dropExited(info: DropInfo) { if targeted == key { targeted = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: alwaysMove || DragModifiers.optionHeld ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = nil
        let option = DragModifiers.optionHeld
        guard let provider = info.itemProviders(for: [accepts.contentType]).first else { return false }
        let handle = self.handle
        _ = provider.loadTransferable(type: SidebarDrag.self) { result in
            guard case .success(let drag) = result else { return }
            Task { @MainActor in handle(drag, option) }
        }
        return true
    }
}
