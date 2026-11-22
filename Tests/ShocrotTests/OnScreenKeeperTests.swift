import AppKit
import Testing
@testable import Shocrot

/// What the keeper does to a real window when it moves or resizes, against a fake display arrangement: a
/// 1512×982 laptop (33 pt menu bar) and a 1920×1050 display to its right. The windows are never ordered in, so
/// nothing appears on screen; they only report themselves visible.
@MainActor
@Suite(.serialized)
struct OnScreenKeeperTests {
    nonisolated static let laptop: WindowPlacement.Display = (CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                  CGRect(x: 0, y: 0, width: 1512, height: 949))
    nonisolated static let external: WindowPlacement.Display = (CGRect(x: 1512, y: 74, width: 1920, height: 1050),
                                                    CGRect(x: 1512, y: 74, width: 1920, height: 1017))
    let m = WindowPlacement.margin

    /// A borderless window that says it is on screen without being shown.
    final class ShownWindow: NSWindow {
        var shown = true
        override var isVisible: Bool { shown }
    }

    /// The fake world the keeper reads: displays and the left mouse button.
    final class World {
        var screens: [WindowPlacement.Display] = [OnScreenKeeperTests.laptop, OnScreenKeeperTests.external]
        var fallback: CGRect? = OnScreenKeeperTests.laptop.visible
        var mouseDown = false
    }

    private func makeWindow(_ frame: CGRect) -> ShownWindow {
        let window = ShownWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeKeeper(_ window: NSWindow, _ world: World, canShrink: Bool = false) -> OnScreenKeeper {
        OnScreenKeeper(window: window, canShrink: canShrink, fallback: { world.fallback },
                       screens: { world.screens }, isMouseDown: { world.mouseDown })
    }

    private func inside(_ f: CGRect, _ visible: CGRect) -> Bool {
        visible.insetBy(dx: m, dy: m).contains(f)
    }

    /// Waits up to `timeout` for `condition`, letting notifications and the keeper's task run.
    private func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func contentGrowingPastTheBottomIsPulledBackUp() async {
        let world = World()
        let window = makeWindow(CGRect(x: 180, y: 600, width: 420, height: 200))
        let keeper = makeKeeper(window, world)
        // The hosting controller grows the window downwards, keeping its top left.
        window.setFrame(CGRect(x: 180, y: 800 - 900, width: 420, height: 900), display: false)
        #expect(await eventually { inside(window.frame, Self.laptop.visible) })
        #expect(window.frame.size == CGSize(width: 420, height: 900))
        withExtendedLifetime(keeper) {}
    }

    @Test func aWindowAlreadyOnScreenIsNotMoved() async {
        let world = World()
        let frame = CGRect(x: 300, y: 300, width: 420, height: 400)
        let window = makeWindow(frame)
        let keeper = makeKeeper(window, world)
        window.setFrameOrigin(CGPoint(x: 320, y: 310))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(window.frame.origin == CGPoint(x: 320, y: 310))
        withExtendedLifetime(keeper) {}
    }

    /// Never fights a drag: a window dragged past the edge stays put while the button is down, then settles.
    @Test func aDragPastTheEdgeSettlesOnlyOnceTheMouseIsReleased() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        world.mouseDown = true
        let dragged = CGPoint(x: 1300, y: -250) // bottom right corner, past the laptop's edges
        window.setFrameOrigin(dragged)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(window.frame.origin == dragged)
        world.mouseDown = false
        #expect(await eventually { inside(window.frame, Self.laptop.visible) })
        withExtendedLifetime(keeper) {}
    }

    /// Every step of a drag moves the window; it settles from where the drag ends, and so does the next drag.
    @Test func eachDragSettlesFromWhereItEnds() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        for _ in 0..<2 {
            world.mouseDown = true
            for x in stride(from: 300.0, through: -400, by: -50) { window.setFrameOrigin(CGPoint(x: x, y: 300)) }
            window.setFrameOrigin(CGPoint(x: -400, y: -300)) // released past the bottom left corner
            try? await Task.sleep(for: .milliseconds(150))
            #expect(window.frame.origin == CGPoint(x: -400, y: -300))
            world.mouseDown = false
            #expect(await eventually { window.frame.origin == CGPoint(x: m, y: m) })
        }
        withExtendedLifetime(keeper) {}
    }

    @Test func aWindowDraggedMostlyOntoTheSecondDisplayIsKeptThere() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        window.setFrameOrigin(CGPoint(x: 3200, y: 20)) // past the external display's bottom right corner
        #expect(await eventually { inside(window.frame, Self.external.visible) })
        withExtendedLifetime(keeper) {}
    }

    @Test func aWindowOnNoDisplayGoesToTheFallback() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        window.setFrameOrigin(CGPoint(x: -3000, y: -3000))
        #expect(await eventually { inside(window.frame, Self.laptop.visible) })
        withExtendedLifetime(keeper) {}
    }

    @Test func aResizableWindowLargerThanItsDisplayIsCutDownToIt() async {
        let world = World()
        let window = makeWindow(CGRect(x: 100, y: 100, width: 880, height: 540))
        let keeper = makeKeeper(window, world, canShrink: true)
        window.setFrame(CGRect(x: 100, y: -300, width: 1800, height: 1300), display: false)
        #expect(await eventually { inside(window.frame, Self.laptop.visible) })
        withExtendedLifetime(keeper) {}
    }

    @Test func aHiddenWindowIsLeftAlone() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        window.shown = false
        let keeper = makeKeeper(window, world)
        window.setFrameOrigin(CGPoint(x: -3000, y: -3000))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(window.frame.origin == CGPoint(x: -3000, y: -3000))
        withExtendedLifetime(keeper) {}
    }

    /// The translation panel is placed before it is shown, possibly taller than planned: it is fitted then.
    @Test func aWindowJustPlacedIsFittedBeforeItIsShown() {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        window.shown = false
        let keeper = makeKeeper(window, world)
        window.setFrameTopLeftPoint(CGPoint(x: 1000, y: 300)) // a 400 pt tall panel from y = 300 runs off
        keeper.pullBackNow()
        #expect(inside(window.frame, Self.laptop.visible))
        #expect(window.frame.size == CGSize(width: 420, height: 400))
    }

    // MARK: Displays changing under a window that does not move

    private func postDisplaysChanged() {
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @Test func unpluggingTheDisplayAWindowIsOnBringsItToTheFallback() async {
        let world = World()
        let window = makeWindow(CGRect(x: 2000, y: 400, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        world.screens = [Self.laptop]
        postDisplaysChanged()
        #expect(await eventually { inside(window.frame, Self.laptop.visible) })
        withExtendedLifetime(keeper) {}
    }

    @Test func aDockGrowingOverAWindowPushesItUp() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 20, width: 420, height: 400))
        let keeper = makeKeeper(window, world)
        let shrunk = CGRect(x: 0, y: 120, width: 1512, height: 829) // a 120 pt Dock along the bottom
        world.screens = [(Self.laptop.frame, shrunk), Self.external]
        postDisplaysChanged()
        #expect(await eventually { inside(window.frame, shrunk) })
        withExtendedLifetime(keeper) {}
    }

    /// Released with its window (the OCR window drops it on close), the keeper stops reacting: nothing is left
    /// observing the window.
    @Test func aReleasedKeeperNoLongerMovesTheWindow() async {
        let world = World()
        let window = makeWindow(CGRect(x: 300, y: 300, width: 420, height: 400))
        var keeper: OnScreenKeeper? = makeKeeper(window, world)
        weak let weakKeeper = keeper
        keeper = nil
        #expect(weakKeeper == nil)
        window.setFrameOrigin(CGPoint(x: -3000, y: -3000))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(window.frame.origin == CGPoint(x: -3000, y: -3000))
    }
}
