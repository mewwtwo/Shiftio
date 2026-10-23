import CoreGraphics

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Position of the handle on a rect.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
    }
}

/// Crop-rect geometry in image pixels, top-left origin. Pure functions so they can be unit-tested.
enum CropMath {
    static let minSide: CGFloat = 16

    static func move(_ start: CGRect, by delta: CGSize, in bounds: CGSize) -> CGRect {
        var rect = start
        rect.origin.x = min(max(0, start.minX + delta.width), bounds.width - start.width)
        rect.origin.y = min(max(0, start.minY + delta.height), bounds.height - start.height)
        return rect
    }

    /// Drags `handle` by `delta`. With a `ratio` (width / height) the opposite corner or edge stays put.
    static func resize(_ start: CGRect, handle: CropHandle, by delta: CGSize,
                       ratio: CGFloat?, in bounds: CGSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = clamp(minX + delta.width, 0, maxX - minSide) }
        if handle.movesRight { maxX = clamp(maxX + delta.width, minX + minSide, bounds.width) }
        if handle.movesTop { minY = clamp(minY + delta.height, 0, maxY - minSide) }
        if handle.movesBottom { maxY = clamp(maxY + delta.height, minY + minSide, bounds.height) }

        guard let ratio else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        let anchorX = handle.movesLeft ? start.maxX : handle.movesRight ? start.minX : start.midX
        let anchorY = handle.movesTop ? start.maxY : handle.movesBottom ? start.minY : start.midY
        let width = maxX - minX, height = maxY - minY

        var newWidth: CGFloat
        if handle.isCorner {
            newWidth = abs(delta.width) >= abs(delta.height) * ratio ? width : height * ratio
        } else {
            newWidth = (handle.movesLeft || handle.movesRight) ? width : height * ratio
        }

        // Room available on each axis from the anchor, converted to a maximum width.
        let roomX = (handle.movesLeft || handle.movesRight)
            ? (handle.movesLeft ? anchorX : bounds.width - anchorX)
            : 2 * min(anchorX, bounds.width - anchorX)
        let roomY = (handle.movesTop || handle.movesBottom)
            ? (handle.movesTop ? anchorY : bounds.height - anchorY)
            : 2 * min(anchorY, bounds.height - anchorY)
        newWidth = min(newWidth, roomX, roomY * ratio)
        newWidth = max(newWidth, minSide, minSide * ratio)
        let newHeight = newWidth / ratio

        let x = handle.movesLeft ? anchorX - newWidth : handle.movesRight ? anchorX : anchorX - newWidth / 2
        let y = handle.movesTop ? anchorY - newHeight : handle.movesBottom ? anchorY : anchorY - newHeight / 2
        return CGRect(x: x, y: y, width: newWidth, height: newHeight)
    }

    /// Largest rect with `ratio` that fits inside `rect`, centred.
    static func fit(_ rect: CGRect, ratio: CGFloat) -> CGRect {
        var width = rect.width, height = rect.height
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
