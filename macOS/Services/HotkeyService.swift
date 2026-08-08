import Foundation
import Carbon
import Cocoa
import ApplicationServices
import QuartzCore

class HotkeyService {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Fired on a "clean tap" of the layout-switch key: pressed and released on
    /// its own, quickly, with nothing else touched in between. See `handleTap`.
    var onLayoutSwitchTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRecordKeyPressed = false

    // Default to fn key; configurable via UserDefaults
    private var hotkeyKeyCode: Int {
        let saved = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return saved != 0 ? saved : ModifierKey.function.canonicalKeyCode
    }

    private var recordKey: ModifierKey? {
        ModifierKey.from(keyCode: hotkeyKeyCode)
    }

    // MARK: - Layout-switch tap state

    /// A tap must complete within this window. Anything slower is the modifier
    /// being held for its normal job (dead keys, ⌥-click, ⌥-scroll), not a tap.
    private static let tapMaxDuration: CFTimeInterval = 0.35

    private var isTapKeyPressed = false
    /// True while the current press is still a tap candidate. Any other key,
    /// modifier, click or scroll clears it.
    private var tapIsClean = false
    private var tapPressedAt: CFTimeInterval = 0

    private var layoutSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "layoutSwitchEnabled")
    }

    private var layoutSwitchKey: ModifierKey? {
        let saved = UserDefaults.standard.integer(forKey: "layoutSwitchKeyCode")
        return ModifierKey.from(keyCode: saved != 0 ? saved : ModifierKey.option.canonicalKeyCode)
    }

    private var retryTimer: Timer?

    /// The tap detector is off when the same modifier is also push-to-talk: one
    /// physical key cannot mean both "record" and "switch layout".
    private var activeTapKey: ModifierKey? {
        guard layoutSwitchEnabled, let key = layoutSwitchKey, key != recordKey else { return nil }
        return key
    }

    /// Whether the live tap was created with pointer events in its mask.
    private var observesPointerEvents = false

    /// Pointer and scroll events are watched only to invalidate an in-flight
    /// tap (⌥-click, ⌥-scroll-to-zoom). They're excluded when
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
        if activeTapKey != nil {
            types += [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        }
        return types
    }

    /// Rebuilds the tap when the layout-switch setting (or the recording key)
    /// changed what needs to be observed. Cheap no-op otherwise, so it's safe to
    /// call from a broad UserDefaults change notification. Main thread only —
    /// `start`/`stop` touch the current run loop.
    func refreshEventMask() {
        guard eventTap != nil, observesPointerEvents != (activeTapKey != nil) else { return }
        flog("HotkeyService.refreshEventMask: rebuilding tap, pointerEvents=\(activeTapKey != nil)")
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
        observesPointerEvents = activeTapKey != nil
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

        if type == .flagsChanged, let recordKey = recordKey {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Match on the modifier rather than the exact code so the right-hand
            // key works too. The flag is derived from the configured key: this
            // used to be hardcoded to fn, so any other push-to-talk key was
            // silently dead.
            if recordKey.keyCodes.contains(keyCode) {
                let isDown = event.flags.contains(recordKey.flag)

                if isDown && !isRecordKeyPressed {
                    isRecordKeyPressed = true
                    flog("HotkeyService: key DOWN (keyCode=\(keyCode))")
                    DispatchQueue.main.async { self.onKeyDown?() }
                } else if !isDown && isRecordKeyPressed {
                    isRecordKeyPressed = false
                    flog("HotkeyService: key UP (keyCode=\(keyCode))")
                    DispatchQueue.main.async { self.onKeyUp?() }
                }
            }
        }

        handleTap(type: type, event: event)

        return Unmanaged.passRetained(event)
    }

    /// Recognises a standalone tap of the configured modifier.
    ///
    /// The event is never consumed — the key keeps working as a modifier,
    /// because the decision is made on *release* and only when nothing else
    /// happened while it was down.
    private func handleTap(type: CGEventType, event: CGEvent) {
        guard let tapKey = activeTapKey else {
            // Don't leave stale state behind if the setting changed mid-press.
            isTapKeyPressed = false
            tapIsClean = false
            return
        }

        switch type {
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isDown = event.flags.contains(tapKey.flag)

            guard tapKey.keyCodes.contains(keyCode) else {
                // Some other modifier changed. If that happened while our key
                // was held, the user is building a chord, not tapping.
                if isTapKeyPressed { tapIsClean = false }
                return
            }

            if isDown && !isTapKeyPressed {
                isTapKeyPressed = true
                tapIsClean = event.flags.isDisjoint(with: tapKey.competingFlags)
                tapPressedAt = CACurrentMediaTime()
            } else if !isDown && isTapKeyPressed {
                isTapKeyPressed = false
                let elapsed = CACurrentMediaTime() - tapPressedAt
                let wasClean = tapIsClean
                tapIsClean = false

                if wasClean && elapsed <= Self.tapMaxDuration {
                    flog("HotkeyService: \(tapKey.symbol) TAP (\(Int(elapsed * 1000))ms)")
                    DispatchQueue.main.async { self.onLayoutSwitchTap?() }
                }
            }

        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            if isTapKeyPressed { tapIsClean = false }

        default:
            break
        }
    }

    deinit {
        stop()
    }
}
