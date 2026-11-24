import CoreGraphics

struct ScrollGesture {
    enum Action: Equatable {
        case pass, suppress, switchProfile(Int)
    }

    private var awaitingBegin = false
    private var inSidebar = false
    private var dx = 0.0, dy = 0.0
    private var fired = false
    private var suppressMomentum = false

    /// Live horizontal swipe progress in `-1.0 ... 1.0` for tactile UI feedback.
    private(set) var progress = 0.0

    mutating func handle(phase rawPhase: Int64, momentum: Int64, dx: Double, dy: Double,
                         threshold: Double = 40, reversed: Bool = false,
                         overSidebar: @autoclosure () -> Bool) -> Action {
        if momentum != 0 {
            let action: Action = suppressMomentum ? .suppress : .pass
            if momentum == CGMomentumScrollPhase.end.rawValue { suppressMomentum = false }
            return action
        }
        guard rawPhase != 0, let phase = CGScrollPhase(rawValue: UInt32(truncatingIfNeeded: rawPhase)) else { return .pass }
        if phase == .mayBegin || (phase == .began && !awaitingBegin) {
            self = ScrollGesture()
            inSidebar = overSidebar()
        }
        awaitingBegin = phase == .mayBegin
        defer {
            if phase == .ended || phase == .cancelled {
                let keepMomentum = fired && phase == .ended
                self = ScrollGesture()
                suppressMomentum = keepMomentum
            }
        }
        guard inSidebar else { return .pass }
        self.dx += dx
        self.dy += dy
        let horizontal = abs(self.dx) > 2 * abs(self.dy)
        let limit = max(12, threshold)
        if horizontal && !fired {
            let raw = self.dx / limit
            progress = max(-1.0, min(1.0, reversed ? -raw : raw))
        } else if !horizontal {
            progress = 0
        }
        if !fired && horizontal && abs(self.dx) > limit {
            fired = true
            suppressMomentum = true
            progress = 0
            let direction = self.dx > 0 ? -1 : 1
            return .switchProfile(reversed ? -direction : direction)
        }
        return fired || horizontal ? .suppress : .pass
    }
}
