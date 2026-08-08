import Foundation
import Carbon
import Cocoa
import ApplicationServices
import QuartzCore

class HotkeyService {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Fired on a "clean tap" of the Option key: pressed and released on its own,
    /// quickly, with nothing else touched in between. See `handleOptionTap`.
    var onLayoutSwitchTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnPressed = false

    // Default to fn key; configurable via UserDefaults
    private var hotkeyKeyCode: Int {
        let saved = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return saved != 0 ? saved : 63 // 63 = fn key
    }

    // MARK: - Option-tap state

    private static let leftOptionKeyCode: Int64 = 58
    private static let rightOptionKeyCode: Int64 = 61

    /// A tap must complete within this window. Anything slower is Option being
    /// held as a modifier (dead keys, Option+click, Option+scroll), not a tap.
    private static let optionTapMaxDuration: CFTimeInterval = 0.35

    /// Holding any of these alongside Option means the user is composing a
    /// shortcut, not tapping. Caps Lock and the numeric-pad flag are excluded on
    /// purpose: they can be latched on permanently and say nothing about intent.
    private static let conflictingModifiers: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskSecondaryFn]

    private var isOptionPressed = false
    /// True while the current Option press is still a tap candidate. Any other
    /// key, modifier, click or scroll clears it.
    private var optionTapIsClean = false
    private var optionPressedAt: CFTimeInterval = 0

    private var layoutSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "layoutSwitchEnabled")
    }

    /// The Option tap is unavailable when Option is also the push-to-talk key —
    /// one physical key cannot mean both "record" and "switch layout".
    private var optionTapAvailable: Bool {
        hotkeyKeyCode != Int(Self.leftOptionKeyCode) && hotkeyKeyCode != Int(Self.rightOptionKeyCode)
    }

    private var retryTimer: Timer?

    private var optionTapDetectorActive: Bool {
        layoutSwitchEnabled && optionTapAvailable
    }

    /// Whether the live tap was created with pointer events in its mask.
    private var observesPointerEvents = false

    /// Pointer and scroll events are watched only to invalidate an in-flight
    /// Option tap (Option+click, Option+scroll-to-zoom). They're excluded when
    /// layout switching is off so a head-inserted tap isn't sitting in the path
    /// of every scroll event for users who never enabled the feature.
    private func observedTypes() -> [CGEventType] {
        var types: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .tapDisabledByTimeout,
            .tapDisabledByUserInput,
        ]
        if optionTapDetectorActive {
            types += [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        }
        return types
    }

    /// Rebuilds the tap when the layout-switch setting (or the recording key)
    /// changed what needs to be observed. Cheap no-op otherwise, so it's safe to
    /// call from a broad UserDefaults change notification. Main thread only —
    /// `start`/`stop` touch the current run loop.
    func refreshEventMask() {
        guard eventTap != nil, observesPointerEvents != optionTapDetectorActive else { return }
        flog("HotkeyService.refreshEventMask: rebuilding tap, pointerEvents=\(optionTapDetectorActive)")
        stop()
        start()
    }

    func start() {
        flog("HotkeyService.start: accessibility=\(AXIsProcessTrusted()), hotkeyKeyCode=\(hotkeyKeyCode)")
        guard eventTap == nil else {
            flog("HotkeyService.start: already started")
            return
        }

        // Built with reduce rather than a chain of `|`: as a single expression
        // the type checker gives up on it.
        observesPointerEvents = optionTapDetectorActive
        let eventMask: CGEventMask = observedTypes().reduce(into: CGEventMask(0)) { mask, type in
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let service = userInfo.map({ Unmanaged<HotkeyService>.fromOpaque($0).takeUnretainedValue() }) else {
                return Unmanaged.passRetained(event)
            }
            return service.handleEvent(proxy: proxy, type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        )

        guard let eventTap = eventTap else {
            flog("HotkeyService.start: FAILED to create event tap, retrying in 3s")
            startRetryTimer()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        flog("HotkeyService.start: event tap created and enabled")
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.start()
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flog("HotkeyService: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "userInput"), re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == hotkeyKeyCode {
                let flags = event.flags
                let fnPressed = flags.contains(.maskSecondaryFn)

                if fnPressed && !isFnPressed {
                    isFnPressed = true
                    flog("HotkeyService: key DOWN (keyCode=\(keyCode))")
                    DispatchQueue.main.async { self.onKeyDown?() }
                } else if !fnPressed && isFnPressed {
                    isFnPressed = false
                    flog("HotkeyService: key UP (keyCode=\(keyCode))")
                    DispatchQueue.main.async { self.onKeyUp?() }
                }
            }
        }

        handleOptionTap(type: type, event: event)

        return Unmanaged.passRetained(event)
    }

    /// Recognises a standalone tap of the Option key.
    ///
    /// The event is never consumed — Option keeps working as a modifier, because
    /// the decision is made on *release* and only when nothing else happened
    /// while the key was down.
    private func handleOptionTap(type: CGEventType, event: CGEvent) {
        guard layoutSwitchEnabled, optionTapAvailable else {
            // Don't leave stale state behind if the feature is toggled off mid-press.
            isOptionPressed = false
            optionTapIsClean = false
            return
        }

        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isOptionKey = keyCode == Self.leftOptionKeyCode || keyCode == Self.rightOptionKeyCode
            let optionDown = event.flags.contains(.maskAlternate)

            guard isOptionKey else {
                // Some other modifier changed. If that happened while Option was
                // held, the user is building a chord, not tapping.
                if isOptionPressed { optionTapIsClean = false }
                return
            }

            if optionDown && !isOptionPressed {
                isOptionPressed = true
                optionTapIsClean = event.flags.isDisjoint(with: Self.conflictingModifiers)
                optionPressedAt = CACurrentMediaTime()
            } else if !optionDown && isOptionPressed {
                isOptionPressed = false
                let elapsed = CACurrentMediaTime() - optionPressedAt
                let wasClean = optionTapIsClean
                optionTapIsClean = false

                if wasClean && elapsed <= Self.optionTapMaxDuration {
                    flog("HotkeyService: Option TAP (\(Int(elapsed * 1000))ms)")
                    DispatchQueue.main.async { self.onLayoutSwitchTap?() }
                }
            }

        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            if isOptionPressed { optionTapIsClean = false }

        default:
            break
        }
    }

    deinit {
        stop()
    }
}
