//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Panel that displays the coding-agent improvement prompt next to the mouse
//  cursor, with a "copied to clipboard" confirmation footer. Uses a
//  non-activating NSPanel so it floats above all apps without stealing focus.
//  The panel is positioned once at show time — it deliberately does not follow
//  the mouse, so the prompt stays readable while the user moves the mouse to
//  look at the problem areas the blue cursor points at.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var improvementPromptText: String = ""
    @Published var isShowingPrompt: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var autoHideWorkItem: DispatchWorkItem?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 420

    /// Shows the improvement prompt near the current mouse location and
    /// schedules an auto-hide based on estimated reading time. The prompt
    /// arrives complete (the pipeline receives the full response before
    /// display), so nothing streams.
    func showImprovementPrompt(_ improvementPromptText: String) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.improvementPromptText = improvementPromptText
        overlayViewModel.isShowingPrompt = true
        createOverlayPanelIfNeeded()

        // Give SwiftUI one runloop tick to lay out the new text before
        // measuring — fittingSize would otherwise report the previous
        // content's size. The panel is only ordered front after sizing and
        // positioning so the user never sees it jump.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlayViewModel.isShowingPrompt else { return }
            self.resizePanelToFitContent()
            self.positionPanelNearCursor()
            self.overlayPanel?.alphaValue = 1
            self.overlayPanel?.orderFrontRegardless()
        }

        scheduleAutoHideAfterEstimatedReadingTime(for: improvementPromptText)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.isShowingPrompt = false
        overlayViewModel.improvementPromptText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    /// Fades the panel out after the user has had time to skim the prompt.
    private func scheduleAutoHideAfterEstimatedReadingTime(for improvementPromptText: String) {
        let promptWordCount = improvementPromptText.split(whereSeparator: { $0.isWhitespace }).count
        // ~200 words-per-minute skim speed, clamped so short prompts stay up
        // long enough to register and long ones don't squat on screen. The
        // full text is already on the clipboard, so the panel is a preview,
        // not the artifact. The panel is also hidden the moment the next
        // push-to-talk interaction begins.
        let autoHideDelaySeconds = min(45.0, max(12.0, Double(promptWordCount) * 0.3))

        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelaySeconds, execute: hideWork)
    }

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func positionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        let newHeight = fittingSize.height

        var frame = overlayPanel.frame
        frame.size = CGSize(width: newWidth, height: newHeight)
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingPrompt {
            VStack(alignment: .leading, spacing: 8) {
                Text("prompt for your coding agent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(viewModel.improvementPromptText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(3)
                    // Backstop against a pathologically long prompt growing the
                    // panel taller than the screen — the clipboard always holds
                    // the full text.
                    .lineLimit(30)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 396, alignment: .leading)

                Rectangle()
                    .fill(DS.Colors.borderSubtle.opacity(0.5))
                    .frame(height: 1)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("copied to clipboard — paste into your coding agent")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.success)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            )
        }
    }
}
