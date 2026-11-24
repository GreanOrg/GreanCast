// MirrorView.swift
// AppKit view that shows the iPhone screen and turns mouse/trackpad/keyboard into gestures:
//   click → tap; click held ≥ 0.45 s without moving → long press;
//   click-drag → the same finger path; wheel/trackpad → scroll (drag from the centre);
//   typing → text in the iPhone's focused field (dead keys and ⌥ combos via NSTextInputClient);
//   ⌘V → pastes the Mac clipboard.
// Positions are sent normalized (0…1); the session converts them to iOS points.

import AppKit
import SwiftUI

/// Events produced by the view, consumed by DeviceSession.
@MainActor
protocol MirrorInputHandler: AnyObject {
    func tap(at p: CGPoint)
    func longPress(at p: CGPoint, ms: Int)
    func gesture(_ points: [(p: CGPoint, ms: Int)])
    func scroll(dx: CGFloat, dy: CGFloat, precise: Bool)
    func typeText(_ s: String)
    func note(_ s: String)
}

final class MirrorNSView: NSView {
    weak var handler: MirrorInputHandler?
    var image: NSImage? { didSet { needsDisplay = true } }

    private var dragStart: (p: CGPoint, view: CGPoint, t: TimeInterval)?
    private var dragPoints: [(p: CGPoint, t: TimeInterval)] = []

    override var isFlipped: Bool { true }            // y grows downwards, like iOS
    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Rect where the frame is drawn (aspect fit), with rounded corners like the device.
    private var imageRect: CGRect {
        guard let img = image, img.size.width > 0, img.size.height > 0 else { return .zero }
        let area = bounds.insetBy(dx: 16, dy: 16)
        let s = min(area.width / img.size.width, area.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let r = imageRect
        // Device-like bezel and rounded screen corners (≈ 12 % of the width on modern iPhones).
        let radius = r.width * 0.12
        let bezel = NSBezierPath(roundedRect: r.insetBy(dx: -6, dy: -6), xRadius: radius + 6, yRadius: radius + 6)
        NSColor(white: 0.08, alpha: 1).setFill()
        bezel.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        image.draw(in: r, from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        drawRipples()
    }

    /// Normalized position (0…1) in the frame, or nil outside it.
    private func normalized(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let v = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0 else { return nil }
        var x = (v.x - r.minX) / r.width, y = (v.y - r.minY) / r.height
        if clamp { x = min(max(x, 0), 1); y = min(max(y, 0), 1) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = normalized(event) else { dragStart = nil; return }
        let v = convert(event.locationInWindow, from: nil)
        dragStart = (p, v, event.timestamp)
        dragPoints = [(p, event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, let p = normalized(event, clamp: true) else { return }
        dragPoints.append((p, event.timestamp))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let v = convert(event.locationInWindow, from: nil)
        let moved = hypot(v.x - start.view.x, v.y - start.view.y)
        let heldMS = Int((event.timestamp - start.t) * 1000)
        if moved < 6 {
            showRipple(at: start.view)
            if heldMS >= 450 { handler?.longPress(at: start.p, ms: heldMS) } else { handler?.tap(at: start.p) }
            return
        }
        if let p = normalized(event, clamp: true) { dragPoints.append((p, event.timestamp)) }
        // Downsample to ~25 points, keeping the first and the last.
        let step = max(1, dragPoints.count / 25)
        var kept = stride(from: 0, to: dragPoints.count, by: step).map { dragPoints[$0] }
        if let last = dragPoints.last, kept.last?.t != last.t { kept.append(last) }
        var out: [(p: CGPoint, ms: Int)] = []
        var prevT = kept.first?.t ?? 0
        for k in kept {
            out.append((k.p, Int((k.t - prevT) * 1000)))
            prevT = k.t
        }
        handler?.gesture(out)
    }

    override func scrollWheel(with event: NSEvent) {
        handler?.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                        precise: event.hasPreciseScrollingDeltas)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            if event.charactersIgnoringModifiers == "v",
               let s = NSPasteboard.general.string(forType: .string) {
                handler?.typeText(s)
                return
            }
            super.keyDown(with: event)   // let menu shortcuts through
            return
        }
        switch event.keyCode {
        case 123, 124, 125, 126:
            handler?.note("Arrow keys are not sent (WebDriverAgent can't synthesize navigation keys)")
        case 53:
            break                                    // Escape: nothing
        default:
            // Go through the macOS text input system: handles dead keys (^ then e → ê), ⌥ combos
            // and composition. The final text arrives in insertText(_:replacementRange:).
            interpretKeyEvents([event])
        }
    }

    // Composition state (pending dead key): not displayed, just tracked.
    fileprivate var marked = ""

    // MARK: Immediate click feedback (the iPhone reacts ~0.5 s later)

    private var ripples: [(center: CGPoint, start: Date)] = []
    private var rippleTimer: Timer?

    func showRipple(at viewPoint: CGPoint) {
        ripples.append((viewPoint, Date()))
        needsDisplay = true
        if rippleTimer == nil {
            rippleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                ripples.removeAll { Date().timeIntervalSince($0.start) > 0.6 }
                needsDisplay = true
                if ripples.isEmpty { t.invalidate(); rippleTimer = nil }
            }
        }
    }

    fileprivate func drawRipples() {
        for r in ripples {
            let age = CGFloat(Date().timeIntervalSince(r.start) / 0.6)
            let radius = 10 + 18 * age
            let path = NSBezierPath(ovalIn: CGRect(x: r.center.x - radius, y: r.center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            NSColor.systemBlue.withAlphaComponent(0.55 * (1 - age)).setFill()
            path.fill()
        }
    }
}

// MARK: - NSTextInputClient (dead keys and composition)

extension MirrorNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        if !s.isEmpty { handler?.typeText(s) }
    }

    /// Command keys translated by macOS (backspace, return, tab…).
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(deleteBackward(_:)): handler?.typeText("\u{8}")
        case #selector(deleteForward(_:)): handler?.typeText("\u{7F}")
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)): handler?.typeText("\n")
        case #selector(insertTab(_:)): handler?.typeText("\t")
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// SwiftUI bridge.
struct MirrorView: NSViewRepresentable {
    let image: NSImage?
    let handler: MirrorInputHandler

    func makeNSView(context: Context) -> MirrorNSView {
        let v = MirrorNSView()
        v.handler = handler
        return v
    }

    func updateNSView(_ v: MirrorNSView, context: Context) {
        v.handler = handler
        if v.image !== image { v.image = image }
    }
}
