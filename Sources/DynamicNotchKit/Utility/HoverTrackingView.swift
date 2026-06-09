//
//  HoverTrackingView.swift
//  DynamicNotchKit
//

import AppKit
import SwiftUI

struct HoverTrackingView: NSViewRepresentable {
    let notchState: DynamicNotchState
    let submitHoverChange: (Bool, DynamicNotchHoverUpdateOrigin) -> Bool

    func makeNSView(context: Context) -> Backing {
        let view = Backing()
        view.notchState = notchState
        view.submitHoverChange = submitHoverChange
        return view
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.submitHoverChange = submitHoverChange
        nsView.updateNotchState(notchState)
    }

    final class Backing: NSView {
        var notchState: DynamicNotchState = .hidden
        var submitHoverChange: ((Bool, DynamicNotchHoverUpdateOrigin) -> Bool)?
        private var acceptedHoverState: Bool?
        private var ownedTrackingArea: NSTrackingArea?
        private var reconciliationTask: Task<Void, Never>?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeOwnedTrackingArea()
                cancelReconciliation()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            removeOwnedTrackingArea()

            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [
                    .activeAlways,
                    .enabledDuringMouseDrag,
                    .inVisibleRect,
                    .mouseEnteredAndExited,
                ],
                owner: self,
                userInfo: nil
            )
            ownedTrackingArea = trackingArea
            addTrackingArea(trackingArea)
        }

        private func removeOwnedTrackingArea() {
            if let ownedTrackingArea, trackingAreas.contains(where: { $0 === ownedTrackingArea }) {
                removeTrackingArea(ownedTrackingArea)
            }
            ownedTrackingArea = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func mouseEntered(with event: NSEvent) {
            submitHoverState(true, origin: .trackingArea)
        }

        override func mouseExited(with event: NSEvent) {
            submitExitIfPointerLeft(origin: .trackingArea)
        }

        // The backing state follows only updates accepted by DynamicNotch.
        // Hidden transition frames may reject reconciliation updates; the
        // next expanded-state reconciliation can then submit the exit again.
        private func submitHoverState(_ hovering: Bool, origin: DynamicNotchHoverUpdateOrigin) {
            guard acceptedHoverState != hovering else {
                return
            }

            guard submitHoverChange?(hovering, origin) == true else {
                return
            }

            acceptedHoverState = hovering

            if hovering {
                reconcileAfterExpansionIfNeeded()
            } else {
                cancelReconciliation()
            }
        }

        func updateNotchState(_ state: DynamicNotchState) {
            guard notchState != state else {
                return
            }

            notchState = state
            reconcileAfterExpansionIfNeeded()
        }

        private func reconcileAfterExpansionIfNeeded() {
            guard acceptedHoverState == true, notchState == .expanded, reconciliationTask == nil else {
                return
            }

            // Repairs exit events that can be lost while the expanded notch is settling.
            reconciliationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: DynamicNotchTransitionConfiguration.settlingDuration)
                guard let self, !Task.isCancelled else {
                    return
                }

                self.reconciliationTask = nil
                self.submitExitIfPointerLeft(origin: .reconciliation)
            }
        }

        private func cancelReconciliation() {
            reconciliationTask?.cancel()
            reconciliationTask = nil
        }

        private func submitExitIfPointerLeft(origin: DynamicNotchHoverUpdateOrigin) {
            guard acceptedHoverState == true, !isPointerInsideHoverRegion else {
                return
            }

            submitHoverState(false, origin: origin)
        }

        private var isPointerInsideHoverRegion: Bool {
            guard let window else {
                return false
            }

            let pointerLocation = NSEvent.mouseLocation
            return boundsContain(pointerLocation, in: window)
                || windowTopEdgeContains(pointerLocation, in: window)
        }

        private func boundsContain(_ screenPoint: NSPoint, in window: NSWindow) -> Bool {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let viewPoint = convert(windowPoint, from: nil)
            return bounds.contains(viewPoint)
        }

        private func windowTopEdgeContains(_ screenPoint: NSPoint, in window: NSWindow) -> Bool {
            guard let screen = window.screen else {
                return false
            }

            return window.frame.minX ... window.frame.maxX ~= screenPoint.x
                && screenPoint.y == screen.frame.maxY
        }
    }
}
