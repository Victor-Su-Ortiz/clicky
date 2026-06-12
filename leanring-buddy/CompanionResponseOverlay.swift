//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Compact confirmation that appears next to the mouse cursor when an
//  improvement prompt has been auto-copied to the clipboard. The full prompt
//  is deliberately NOT displayed — it lives on the clipboard, and showing it
//  on screen proved distracting. Uses a non-activating NSPanel so it floats
//  above all apps without stealing focus, positioned once at show time.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var isShowingConfirmation: Bool = false
    @Published var confirmationMessage: String = ""
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
    private let overlayMaxWidth: CGFloat = 320
    /// How long the confirmation stays up. Short and fixed — it carries one
    /// line of information. Also hidden when the next push-to-talk begins.
    private let confirmationAutoHideDelaySeconds: TimeInterval = 8

    /// Shows a one-line confirmation (e.g. "prompt copied" or "applied N
    /// fixes") near the current mouse location and schedules its auto-hide.
    func showConfirmation(message: String) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.confirmationMessage = message
        overlayViewModel.isShowingConfirmation = true
        createOverlayPanelIfNeeded()

        // Give SwiftUI one runloop tick to lay out before measuring —
        // fittingSize would otherwise report the previous content's size.
        // The panel is only ordered front after sizing and positioning so
        // the user never sees it jump.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlayViewModel.isShowingConfirmation else { return }
            self.resizePanelToFitContent()
            self.positionPanelNearCursor()
            self.overlayPanel?.alphaValue = 1
            self.overlayPanel?.orderFrontRegardless()
        }

        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmationAutoHideDelaySeconds, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.isShowingConfirmation = false
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

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
        if viewModel.isShowingConfirmation {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.success)
                Text(viewModel.confirmationMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
