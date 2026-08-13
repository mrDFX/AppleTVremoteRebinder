//
//  CursorController.swift
//  AppleTVremoteRebinder
//

import CoreGraphics
import CoreFoundation
import Foundation
import AppKit

final class CursorController {
    struct PhysicalClickSnapshot {
        let isActive: Bool
        let isDragging: Bool
        let revision: UInt64
    }

    private let physicalClickLock = NSLock()
    private var _isDragging = false
    private var _isClickActive = false
    private var _physicalClickRevision: UInt64 = 0

    private var clickAnchor: CGPoint?
    private var smoothedDX: CGFloat = 0
    private var smoothedDY: CGFloat = 0

    private func currentCursorPosition() -> CGPoint {
        if let event = CGEvent(source: nil) { return event.location }
        let p = NSEvent.mouseLocation
        guard let main = NSScreen.main else { return p }
        return CGPoint(x: p.x, y: main.frame.maxY - p.y)
    }

    var physicalClickSnapshot: PhysicalClickSnapshot {
        physicalClickLock.lock()
        defer { physicalClickLock.unlock() }
        return PhysicalClickSnapshot(
            isActive: _isClickActive,
            isDragging: _isDragging,
            revision: _physicalClickRevision
        )
    }

    func beginPhysicalClick() {
        cancelPhysicalClick()
        let anchor = currentCursorPosition()
        physicalClickLock.lock()
        _physicalClickRevision &+= 1
        _isClickActive = true
        clickAnchor = anchor
        physicalClickLock.unlock()
    }

    func beginDrag() {
        physicalClickLock.lock()
        guard _isClickActive, !_isDragging else {
            physicalClickLock.unlock()
            return
        }
        _isDragging = true
        let anchor = clickAnchor
        physicalClickLock.unlock()
        let position = physicalClickPosition(anchor: anchor)
        postMouse(.leftMouseDown, at: position, button: .left)
    }

    func endPhysicalClick() {
        physicalClickLock.lock()
        guard _isClickActive else {
            physicalClickLock.unlock()
            return
        }
        let wasDragging = _isDragging
        let anchor = clickAnchor
        clearPhysicalClickStateLocked()
        physicalClickLock.unlock()

        if wasDragging {
            let position = currentCursorPosition()
            postMouse(.leftMouseUp, at: position, button: .left)
        } else {
            performClick(at: physicalClickPosition(anchor: anchor))
        }
    }

    func cancelPhysicalClick() {
        physicalClickLock.lock()
        guard _isClickActive || _isDragging else {
            physicalClickLock.unlock()
            return
        }
        let wasDragging = _isDragging
        clearPhysicalClickStateLocked()
        physicalClickLock.unlock()

        if wasDragging {
            postMouse(.leftMouseUp, at: currentCursorPosition(), button: .left)
        }
    }

    private func physicalClickPosition(anchor: CGPoint?) -> CGPoint {
        if TrackpadPreferences.clickLock, let anchor { return anchor }
        return currentCursorPosition()
    }

    private func clearPhysicalClickStateLocked() {
        _isDragging = false
        _isClickActive = false
        clickAnchor = nil
    }

    /// Smooth relative movement. During a pending physical click, cursor movement is frozen so
    /// pressing the glass does not move the pointer off the intended control. Once drag begins,
    /// movement resumes as leftMouseDragged.
    @discardableResult
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let click = physicalClickSnapshot
        if click.isActive && !click.isDragging && TrackpadPreferences.clickLock {
            return (false, false)
        }

        let sensitivity = CGFloat(TrackpadPreferences.sensitivity)
        let smoothing = CGFloat(TrackpadPreferences.smoothing)
        let deadZone = CGFloat(TrackpadPreferences.deadZone) * 500.0
        var rawX = deltaX * sensitivity
        var rawY = deltaY * sensitivity
        if abs(rawX) < deadZone { rawX = 0 }
        if abs(rawY) < deadZone { rawY = 0 }

        smoothedDX = smoothedDX * smoothing + rawX * (1 - smoothing)
        smoothedDY = smoothedDY * smoothing + rawY * (1 - smoothing)

        let before = currentCursorPosition()
        let target = CGPoint(x: before.x + smoothedDX, y: before.y + smoothedDY)
        let type: CGEventType = click.isDragging ? .leftMouseDragged : .mouseMoved
        postMouse(type, at: target, button: .left)
        return (false, false)
    }

    func resetMotionFilter() {
        smoothedDX = 0
        smoothedDY = 0
    }

    func performClick() { performClick(at: currentCursorPosition()) }

    func performClick(at position: CGPoint) {
        postMouse(.leftMouseDown, at: position, button: .left)
        usleep(18000)
        postMouse(.leftMouseUp, at: position, button: .left)
    }

    func performRightClick() {
        let p = currentCursorPosition()
        postMouse(.rightMouseDown, at: p, button: .right)
        usleep(18000)
        postMouse(.rightMouseUp, at: p, button: .right)
    }

    func scroll(deltaX: Int32, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }
}
