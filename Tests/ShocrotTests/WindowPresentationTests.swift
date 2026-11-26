import AppKit
import CoreGraphics
import Testing
@testable import Shocrot

@Suite("Window presentation")
struct WindowPresentationTests {
    @Test func centeredFramePlacesWindowInMiddleOfVisibleArea() {
        let visible = CGRect(x: 0, y: 70, width: 1920, height: 980)
        let frame = WindowPresentation.centeredFrame(size: CGSize(width: 740, height: 640), in: visible)
        #expect(frame == CGRect(x: 590, y: 240, width: 740, height: 640))
    }

    @Test func centeredFrameWorksOnOffsetSecondaryDisplay() {
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1415)
        let frame = WindowPresentation.centeredFrame(size: CGSize(width: 740, height: 640), in: secondary)
        #expect(frame.midX == secondary.midX)
        #expect(frame.minX >= secondary.minX + WindowPlacement.margin)
        #expect(frame.maxY <= secondary.maxY - WindowPlacement.margin)
    }

    @Test func centeredFrameKeepsTopLeftReachableOnTinyDisplay() {
        let tiny = CGRect(x: 0, y: 0, width: 640, height: 480)
        let frame = WindowPresentation.centeredFrame(size: CGSize(width: 740, height: 640), in: tiny)
        #expect(frame.minX == WindowPlacement.margin)
        #expect(frame.maxY == tiny.maxY - WindowPlacement.margin)
    }

    @Test func relocatesOnlyWhenVisibleOnAnotherSpace() {
        #expect(WindowPresentation.shouldRelocateToActiveSpace(isVisible: true, isOnActiveSpace: false))
        #expect(!WindowPresentation.shouldRelocateToActiveSpace(isVisible: true, isOnActiveSpace: true))
        #expect(!WindowPresentation.shouldRelocateToActiveSpace(isVisible: false, isOnActiveSpace: false))
        #expect(!WindowPresentation.shouldRelocateToActiveSpace(isVisible: false, isOnActiveSpace: true))
    }

    @Test func reopenOpensSettingsUnlessAnotherTitledWindowIsVisibleOnActiveSpace() {
        // Nothing visible or only floating panels (pins, translate panel): open Settings.
        #expect(WindowPresentation.reopenAction(settingsOpen: false, hasVisibleTitledOnActiveSpace: false) == .showSettings)
        // Settings is open (behind another app, minimized, or on another Space): always bring Settings forward.
        #expect(WindowPresentation.reopenAction(settingsOpen: true, hasVisibleTitledOnActiveSpace: false) == .showSettings)
        #expect(WindowPresentation.reopenAction(settingsOpen: true, hasVisibleTitledOnActiveSpace: true) == .showSettings)
        // Another titled window (e.g. History/OCR) is visible on the active Space and Settings is closed.
        #expect(WindowPresentation.reopenAction(settingsOpen: false, hasVisibleTitledOnActiveSpace: true) == .frontExistingTitled)
    }

    @MainActor
    @Test func prepareAddsMoveToActiveSpaceAndRecoversOffScreenWindow() {
        let virtualDisplay = CGRect(x: -5000, y: -5000, width: 1920, height: 1080)
        let virtualVisible = CGRect(x: -5000, y: -4930, width: 1920, height: 980)
        let window = NSWindow(contentRect: CGRect(x: -9000, y: -9000, width: 740, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Never orders onto the real screen; verifies Space behavior + off-screen recovery + centering.
        WindowPresentation.prepare(window, centerOnMouseScreenWhenHidden: true,
                                   preferredSize: CGSize(width: 740, height: 640),
                                   displays: [(virtualDisplay, virtualVisible)],
                                   mouseVisibleFrame: virtualVisible)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.frame == WindowPresentation.centeredFrame(size: CGSize(width: 740, height: 640), in: virtualVisible))
        #expect(!window.isVisible)
    }
}
