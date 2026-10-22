import SwiftUI
import ImageAssetManagerCore

struct RefinementPanelView: View {
    @Bindable var session: PromptRefinementSession
    var onAccept: () -> Void
    var onDismiss: () -> Void

    @State private var replyText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().overlay(Color.appBorder)

            #if os(macOS)
            HStack(alignment: .top, spacing: 0) {
                draftColumn
                Divider().overlay(Color.appBorder)
                suggestionColumn
            }
            .frame(minHeight: 130)
            Divider().overlay(Color.appBorder)
            #endif

            conversationStrip
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appBorder, lineWidth: 1)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Color.appAccent)
            Text("Refine with Claude")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appTextPrimary)
            Spacer()
            Picker("", selection: $session.mode) {
                ForEach(PromptRefinementSession.Mode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close refinement panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Draft column (macOS)

    #if os(macOS)
    private var draftColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR DRAFT")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .kerning(0.5)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            TextEditor(text: $session.draftPrompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.appBackground)
                .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    private var suggestionColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CLAUDE'S SUGGESTION")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .kerning(0.5)
                Spacer()
                if !session.refinedPrompt.isEmpty {
                    Button("Accept →", action: onAccept)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if session.isLoading && session.refinedPrompt.isEmpty {
                ShimmerView()
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding(6)
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $session.refinedPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.indigo.opacity(0.05))
                        .frame(maxWidth: .infinity, minHeight: 100)
                    if session.refinedPrompt.isEmpty {
                        Text("Suggestion will appear here…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                            .allowsHitTesting(false)
                            .padding(10)
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Conversation strip

    private var conversationStrip: some View {
        VStack(spacing: 0) {
            let visible = session.visibleTurns
            if !visible.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(visible.enumerated()), id: \.offset) { index, turn in
                                refinementBubble(turn: turn)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 110)
                    .onChange(of: visible.count) { _, count in
                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                Divider().overlay(Color.appBorder)
            }

            HStack(spacing: 8) {
                if session.mode == .interview && !session.isComplete {
                    TextField("Your reply…", text: $replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appTextPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                        .onSubmit { submitReply() }
                }

                if let err = session.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 200)
                }

                Spacer()

                actionButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if session.mode == .refine {
            refinementActionButton(label: "✦ Refine", loadingLabel: "Refining…") {
                Task { await session.refine() }
            }
        } else if session.isComplete {
            Button("Accept →", action: onAccept)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 6))
                .buttonStyle(.plain)
        } else if session.conversation.isEmpty {
            refinementActionButton(label: "✦ Ask Claude", loadingLabel: "Thinking…") {
                Task { await session.startInterview() }
            }
        } else {
            refinementActionButton(label: "Send", loadingLabel: "Thinking…") {
                submitReply()
            }
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func refinementActionButton(label: String, loadingLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if session.isLoading { ProgressView().controlSize(.mini).tint(.white) }
                Text(session.isLoading ? loadingLabel : label)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(session.isLoading ? Color.appSurfaceRaised : Color.appAccent, in: RoundedRectangle(cornerRadius: 6))
        .buttonStyle(.plain)
        .disabled(session.isLoading)
    }

    private func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        Task { await session.addUserReply(text) }
    }
}

// MARK: - Bubble

private func refinementBubble(turn: RefinementConversationTurn) -> some View {
    Group {
        if turn.role == "user" {
            HStack {
                Spacer(minLength: 40)
                Text(turn.content)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appAccent)
                    .padding(.top, 5)
                Text(assistantDisplayText(for: turn))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 40)
            }
        }
    }
}

private func assistantDisplayText(for turn: RefinementConversationTurn) -> String {
    guard let start = turn.content.firstIndex(of: "{"),
          let end = turn.content.lastIndex(of: "}"),
          let data = String(turn.content[start...end]).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return turn.content
    }
    if let done = json["done"] as? Bool, done {
        return json["rationale"] as? String ?? "Refinement complete."
    }
    return json["rationale"] as? String ?? turn.content
}

// MARK: - Shimmer

struct ShimmerView: View {
    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.appSurfaceRaised.opacity(animating ? 0.7 : 0.3))
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: animating)
            .onAppear { animating = true }
    }
}

// MARK: - iPad sheet wrapper

struct RefinementSheetView: View {
    @Bindable var session: PromptRefinementSession
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showConversation = false
    @State private var replyText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        draftSection
                        Divider().overlay(Color.appBorder)
                        suggestionSection
                    }
                }

                // Bottom drawer peek
                VStack(spacing: 0) {
                    Button {
                        withAnimation { showConversation.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.caption)
                            Text(showConversation ? "Hide Conversation" : "Show Conversation")
                                .font(.system(size: 12))
                            Spacer()
                            Image(systemName: showConversation ? "chevron.down" : "chevron.up")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(Color.appSurface)

                    if showConversation {
                        Divider().overlay(Color.appBorder)
                        RefinementPanelView(
                            session: session,
                            onAccept: { onAccept(); dismiss() },
                            onDismiss: { dismiss() }
                        )
                        .frame(height: 280)
                    }
                }
                .background(Color.appSurface)
                .overlay(alignment: .top) {
                    Divider().overlay(Color.appBorder)
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Refine with Claude")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        onAccept()
                        dismiss()
                    }
                    .disabled(session.refinedPrompt.isEmpty)
                    .tint(Color.appAccent)
                }
            }
        }
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR DRAFT")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .kerning(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            TextEditor(text: $session.draftPrompt)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.appTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.appSurface)
                .frame(minHeight: 120)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CLAUDE'S SUGGESTION")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .kerning(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            if session.isLoading && session.refinedPrompt.isEmpty {
                ShimmerView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                TextEditor(text: $session.refinedPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.appTextPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.indigo.opacity(0.05))
                    .frame(minHeight: 120)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
}
