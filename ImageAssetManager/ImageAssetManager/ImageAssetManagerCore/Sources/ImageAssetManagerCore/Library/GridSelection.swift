import Foundation

/// The Mac way of selecting images in the grid, as pure functions on the grid's order, so the
/// rules are tested without a view.
public struct GridSelection: Sendable, Equatable {
    public enum Click: Sendable { case plain, command, shift }

    public private(set) var selected: Set<String> = []
    /// The last image clicked without ⇧; a ⇧-click selects the range from here.
    public private(set) var anchor: String?

    public init(selected: Set<String> = [], anchor: String? = nil) {
        self.selected = selected
        self.anchor = anchor
    }

    /// The images from `anchor` to `target` inclusive, in grid order, whichever comes first.
    /// An anchor that is not in the grid (scrolled out of the view, filtered away) gives just the target;
    /// a target that is not in the grid gives nothing.
    public static func range(order: [String], anchor: String?, to target: String) -> [String] {
        guard let t = order.firstIndex(of: target) else { return [] }
        guard let anchor, let a = order.firstIndex(of: anchor) else { return [target] }
        return Array(order[min(a, t)...max(a, t)])
    }

    /// A click: plain selects only this image and anchors there; ⌘ adds or removes it and anchors there;
    /// ⇧ replaces the selection with the range from the anchor (the anchor stays).
    public mutating func click(_ id: String, _ kind: Click, order: [String]) {
        switch kind {
        case .plain:
            selected = [id]
            anchor = id
        case .command:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        case .shift:
            selected = Set(Self.range(order: order, anchor: anchor, to: id))
            if anchor == nil || !order.contains(anchor!) { anchor = id }
        }
    }

    /// ⌘A: every image in the current view.
    public mutating func selectAll(order: [String]) {
        selected = Set(order)
        if anchor == nil || !order.contains(anchor!) { anchor = order.first }
    }

    /// Esc.
    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// What a context menu or a drag acts on: the whole selection when the image is in it, else that image alone.
    public func actedOn(_ id: String) -> Set<String> {
        selected.contains(id) ? selected : [id]
    }
}
