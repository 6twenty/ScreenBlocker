import AppKit

/// Modal PIN prompts (and the plain quit confirmation). Each runs its own modal loop while the schedule timer
/// keeps ticking, so callers re-check that what they're authorising is still current once a prompt returns.
enum PinPrompt {
    /// Only one prompt at a time
    private static var isShowing = false

    /// Close an open prompt as if cancelled (e.g. the system is logging out)
    static func cancelOpenPrompt() {
        if isShowing {
            NSApp.abortModal()
        }
    }

    /// Ask for the current PIN until it's entered correctly. Returns it, or nil if cancelled,
    /// or if `cancelIf` becomes true while the prompt is open (e.g. the block it's for has ended).
    static func requestPin(
        title: String,
        message: String,
        lock: PinLock = .shared,
        cancelIf shouldCancel: (() -> Bool)? = nil
    ) -> String? {
        guard !isShowing else { return nil }
        isShowing = true
        defer { isShowing = false }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "PIN"

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        while true {
            guard run(alert, cancelIf: shouldCancel) == .alertFirstButtonReturn else { return nil }
            if lock.verify(field.stringValue) {
                return field.stringValue
            }
            alert.informativeText = "That PIN isn't right. \(message)"
            field.stringValue = ""
        }
    }

    /// Ask to confirm something without a PIN. Returns false if cancelled or closed by `cancelOpenPrompt`.
    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        guard !isShowing else { return false }
        isShowing = true
        defer { isShowing = false }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return run(alert, cancelIf: nil) == .alertFirstButtonReturn
    }

    /// Ask for a new PIN, entered twice. Returns it, or nil if cancelled.
    static func requestNewPin() -> String? {
        guard !isShowing else { return nil }
        isShowing = true
        defer { isShowing = false }

        let pinField = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 24))
        pinField.placeholderString = "New PIN"
        let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        confirmField.placeholderString = "Confirm PIN"
        pinField.nextKeyView = confirmField
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 54))
        fields.addSubview(pinField)
        fields.addSubview(confirmField)

        let message = "Enter \(PinLock.lengthRange.lowerBound)–\(PinLock.lengthRange.upperBound) digits. You'll need it to unlock Settings, quit, or exit a block early."
        let alert = NSAlert()
        alert.messageText = "Set a PIN"
        alert.informativeText = message
        alert.accessoryView = fields
        alert.addButton(withTitle: "Set PIN")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = pinField

        while true {
            guard run(alert, cancelIf: nil) == .alertFirstButtonReturn else { return nil }
            let pin = pinField.stringValue
            if !PinLock.isValidPin(pin) {
                alert.informativeText = "The PIN must be digits only. \(message)"
            } else if confirmField.stringValue != pin {
                alert.informativeText = "The PINs didn't match. \(message)"
            } else {
                return pin
            }
            pinField.stringValue = ""
            confirmField.stringValue = ""
            alert.window.makeFirstResponder(pinField)
        }
    }

    private static func run(_ alert: NSAlert, cancelIf shouldCancel: (() -> Bool)?) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)

        var watcher: Timer?
        if let shouldCancel {
            let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
                if shouldCancel() {
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            watcher = timer
        }
        defer { watcher?.invalidate() }

        return alert.runModal()
    }
}
