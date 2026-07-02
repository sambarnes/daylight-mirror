// ArrangementView.swift — Drag-and-drop display arrangement canvas.
//
// Shows every online display (built-in, physical externals, and Daylight virtual
// displays) as a draggable tile, scaled to fit. Dragging a tile and releasing
// applies the new position via CGConfigureDisplayOrigin. macOS normalizes the
// final layout (snaps displays edge-to-edge, removes gaps/overlaps), and the
// canvas refreshes to show the normalized result.
//
// Same coordinate space as CGDisplayBounds: origin at the primary display's
// top-left, y increasing downward — which conveniently matches SwiftUI.

import SwiftUI
import MirrorEngine

// MARK: - Display Model

struct ArrangedDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var bounds: CGRect
    let name: String
    let isBuiltIn: Bool
    let isVirtual: Bool

    var isPrimary: Bool { bounds.origin == .zero && isBuiltIn }
}

// MARK: - Arrangement View

struct ArrangementView: View {
    @ObservedObject var engine: MirrorEngine

    @State private var displays: [ArrangedDisplay] = []
    /// ID of the tile currently being dragged, and its live offset in canvas points.
    @State private var draggingID: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero

    private let canvasSize = CGSize(width: 520, height: 320)

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag displays to arrange them. Positions apply when you release.")
                .font(.caption)
                .foregroundStyle(.secondary)

            canvas
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))

            HStack {
                Button("Refresh") { refresh() }
                    .controlSize(.small)
                Spacer()
                Text("Tip: System Settings › Displays offers the same controls.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // External monitor plugged/unplugged or layout changed elsewhere
            if draggingID == nil { refresh() }
        }
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        let transform = canvasTransform()
        ZStack {
            ForEach(displays) { display in
                displayTile(display, transform: transform)
            }
        }
    }

    @ViewBuilder
    private func displayTile(_ display: ArrangedDisplay, transform: (scale: CGFloat, offset: CGPoint)) -> some View {
        let rect = scaled(display.bounds, transform)
        let isDragging = draggingID == display.id
        let offset = isDragging ? dragOffset : .zero

        RoundedRectangle(cornerRadius: 6)
            .fill(display.isVirtual ? Color.orange.opacity(0.25) : Color.blue.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        display.isPrimary ? Color.primary : (display.isVirtual ? Color.orange : Color.blue),
                        lineWidth: isDragging ? 2.5 : 1.5
                    )
            )
            .overlay(
                VStack(spacing: 2) {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 14))
                    Text(display.name)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(Int(display.bounds.width))×\(Int(display.bounds.height))")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    if display.isPrimary {
                        Text("Primary")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(2)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX + offset.width, y: rect.midY + offset.height)
            .shadow(radius: isDragging ? 6 : 0)
            .zIndex(isDragging ? 1 : 0)
            .gesture(dragGesture(for: display, transform: transform))
            .animation(.easeOut(duration: 0.15), value: displays)
    }

    private func dragGesture(for display: ArrangedDisplay, transform: (scale: CGFloat, offset: CGPoint)) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // The primary display anchors the coordinate space — dragging it
                // would just shift everything else. Let users drag the others.
                guard !display.isPrimary else { return }
                draggingID = display.id
                dragOffset = value.translation
            }
            .onEnded { value in
                defer { draggingID = nil; dragOffset = .zero }
                guard !display.isPrimary else { return }
                let newOrigin = CGPoint(
                    x: display.bounds.origin.x + value.translation.width / transform.scale,
                    y: display.bounds.origin.y + value.translation.height / transform.scale
                )
                apply(displayID: display.id, origin: snap(newOrigin, for: display))
            }
    }

    // MARK: Geometry

    /// Scale + offset that fits all display bounds into the canvas with padding.
    private func canvasTransform() -> (scale: CGFloat, offset: CGPoint) {
        guard !displays.isEmpty else { return (1, .zero) }
        var union = displays[0].bounds
        for d in displays.dropFirst() { union = union.union(d.bounds) }
        // Leave headroom so tiles can be dragged beyond current bounds
        let padding: CGFloat = 40
        let scale = min(
            (canvasSize.width - padding * 2) / max(union.width, 1),
            (canvasSize.height - padding * 2) / max(union.height, 1)
        )
        let offset = CGPoint(
            x: (canvasSize.width - union.width * scale) / 2 - union.origin.x * scale,
            y: (canvasSize.height - union.height * scale) / 2 - union.origin.y * scale
        )
        return (scale, offset)
    }

    private func scaled(_ bounds: CGRect, _ t: (scale: CGFloat, offset: CGPoint)) -> CGRect {
        CGRect(
            x: bounds.origin.x * t.scale + t.offset.x,
            y: bounds.origin.y * t.scale + t.offset.y,
            width: bounds.width * t.scale,
            height: bounds.height * t.scale
        )
    }

    /// Light edge snapping: align the dragged display's edges to nearby edges of
    /// other displays (within threshold, in display points). macOS normalizes the
    /// rest (closing gaps) when the configuration commits.
    private func snap(_ origin: CGPoint, for display: ArrangedDisplay) -> CGPoint {
        let threshold: CGFloat = 80
        var snapped = origin
        let w = display.bounds.width
        let h = display.bounds.height

        for other in displays where other.id != display.id {
            let o = other.bounds
            // Horizontal: snap left edge to other's right, or right edge to other's left
            if abs(origin.x - o.maxX) < threshold { snapped.x = o.maxX }
            if abs((origin.x + w) - o.minX) < threshold { snapped.x = o.minX - w }
            // Align left edges / tops when stacking vertically
            if abs(origin.x - o.minX) < threshold { snapped.x = o.minX }
            // Vertical: snap top to other's bottom, or bottom to other's top
            if abs(origin.y - o.maxY) < threshold { snapped.y = o.maxY }
            if abs((origin.y + h) - o.minY) < threshold { snapped.y = o.minY - h }
            if abs(origin.y - o.minY) < threshold { snapped.y = o.minY }
        }
        return snapped
    }

    // MARK: CoreGraphics I/O

    private func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)

        let virtualIDs = Set(engine.sessions.compactMap { $0.virtualDisplayID })
        // Map displayID → session for nicer names on virtual displays
        let sessionByDisplay = Dictionary(uniqueKeysWithValues:
            engine.sessions.compactMap { s in s.virtualDisplayID.map { ($0, s) } })

        var result: [ArrangedDisplay] = []
        for i in 0..<Int(count) {
            let id = ids[i]
            // Skip mirror followers — they share bounds with their source
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { continue }
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let isVirtual = virtualIDs.contains(id)
            var name = screenName(for: id) ?? (isBuiltIn ? "Built-in" : "Display \(id)")
            if let session = sessionByDisplay[id] {
                name = "\(session.device.deviceFamily.rawValue)\n\(session.device.serial)"
            }
            result.append(ArrangedDisplay(
                id: id, bounds: CGDisplayBounds(id),
                name: name, isBuiltIn: isBuiltIn, isVirtual: isVirtual
            ))
        }
        displays = result
    }

    private func screenName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               num.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return nil
    }

    private func apply(displayID: CGDirectDisplayID, origin: CGPoint) {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            NSLog("[Arrange] Failed to move display %u", displayID)
            CGCancelDisplayConfiguration(config)
        }
        // Refresh after macOS normalizes the layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refresh() }
    }
}
