import Foundation
import Carbon
import Cocoa
import ApplicationServices

class HotkeyService {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnPressed = false

    // Default to fn key; configurable via UserDefaults
    private var hotkeyKeyCode: Int {
        let saved = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return saved != 0 ? saved : 63 // 63 = fn key
    }

    private var retryTimer: Timer?

    func start() {
        flog("HotkeyService.start: accessibility=\(AXIsProcessTrusted()), hotkeyKeyCode=\(hotkeyKeyCode)")
        guard eventTap == nil else {
            flog("HotkeyService.start: already started")
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

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

        return Unmanaged.passRetained(event)
    }

    deinit {
        stop()
    }
}
