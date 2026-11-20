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

    mutating func handle(phase rawPhase: Int64, momentum: Int64, dx: Double, dy: Double,
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
        if !fired && horizontal && abs(self.dx) > 40 {
            fired = true
            suppressMomentum = true
            return .switchProfile(self.dx > 0 ? -1 : 1)
        }
        return fired || horizontal ? .suppress : .pass
    }
}
