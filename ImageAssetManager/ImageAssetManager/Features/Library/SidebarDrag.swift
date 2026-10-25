import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// What is dragged inside the window: images from the grid, or a project from the sidebar. One type,
/// so every target decodes the same thing and ignores what it does not take.
enum SidebarDrag: Codable, Transferable, Sendable {
    case images([String])
    case project(String)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
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
    @Binding var targeted: String?
    /// True for a target whose drop is always a move (a project onto a client).
    let alwaysMove: Bool
    let handle: @MainActor @Sendable (SidebarDrag, _ optionHeld: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.json]) }

    func dropEntered(info: DropInfo) { targeted = key }

    func dropExited(info: DropInfo) { if targeted == key { targeted = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: alwaysMove || DragModifiers.optionHeld ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = nil
        let option = DragModifiers.optionHeld
        guard let provider = info.itemProviders(for: [.json]).first else { return false }
        let handle = self.handle
        _ = provider.loadTransferable(type: SidebarDrag.self) { result in
            guard case .success(let drag) = result else { return }
            Task { @MainActor in handle(drag, option) }
        }
        return true
    }
}
