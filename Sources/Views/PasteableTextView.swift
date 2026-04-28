import SwiftUI
import AppKit

/// Imperative handle for actions a parent view needs to drive against the
/// underlying NSTextView (e.g. replacing the field with a slash-command
/// completion when the user clicks an item rather than pressing Return).
@MainActor
final class PasteableTextViewController {
    weak var textView: NSTextView?

    /// Replaces the field's full contents with `text` and parks the caret at
    /// the end. Routes through `shouldChangeText`/`didChangeText` so the
    /// delegate's `textDidChange` fires and the SwiftUI binding stays in
    /// sync.
    func replaceAll(with text: String) {
        guard let tv = textView else { return }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        if tv.shouldChangeText(in: fullRange, replacementString: text) {
            tv.replaceCharacters(in: fullRange, with: text)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}

struct PasteableTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var onReturn: () -> Void
    var onEscape: () -> Void
    var onImagePaste: (NSImage, Data) -> Void
    /// When true, plain Return fires `onReturn` (and Shift+Return inserts a
    /// newline). When false, plain Return inserts a newline and only
    /// Cmd+Return fires `onReturn`. Cmd+Return fires `onReturn` in both
    /// modes.
    var sendOnReturn: Bool = true
    /// Optional imperative controller. When non-nil, `makeNSView` wires the
    /// underlying NSTextView into it so the parent can mutate the field
    /// directly.
    var controller: PasteableTextViewController? = nil
    /// When `menuActive()` returns true, Up/Down/Tab/Return/Escape are
    /// routed to the menu callbacks instead of the default behaviors.
    var menuActive: () -> Bool = { false }
    var onMenuMove: (Int) -> Void = { _ in }
    /// Called when the user commits the menu selection (Return or Tab).
    /// Returning a non-nil string replaces the entire field with that text
    /// and moves the caret to the end. Returning nil falls through to the
    /// default Return/Tab behavior.
    var onMenuCommit: () -> String? = { nil }
    var onMenuCancel: () -> Void = { }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.onImagePaste = onImagePaste
        textView.onReturn = onReturn
        textView.onEscape = onEscape
        textView.sendOnReturn = sendOnReturn
        textView.menuActive = menuActive
        textView.onMenuMove = onMenuMove
        textView.onMenuCommit = onMenuCommit
        textView.onMenuCancel = onMenuCancel
        controller?.textView = textView
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        context.coordinator.textView = textView

        // Auto-focus
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ImagePasteTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.textColor = textColor
        textView.onImagePaste = onImagePaste
        textView.onReturn = onReturn
        textView.onEscape = onEscape
        textView.sendOnReturn = sendOnReturn
        textView.menuActive = menuActive
        textView.onMenuMove = onMenuMove
        textView.onMenuCommit = onMenuCommit
        textView.onMenuCancel = onMenuCancel
        controller?.textView = textView
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextView
        weak var textView: NSTextView?

        init(_ parent: PasteableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

final class ImagePasteTextView: NSTextView {
    var onImagePaste: ((NSImage, Data) -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var sendOnReturn: Bool = true
    var menuActive: () -> Bool = { false }
    var onMenuMove: (Int) -> Void = { _ in }
    var onMenuCommit: () -> String? = { nil }
    var onMenuCancel: () -> Void = { }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

        // Check for image data on the pasteboard
        if let bestType = pasteboard.availableType(from: imageTypes),
           let imageData = pasteboard.data(forType: bestType) {
            // Convert to PNG
            if let bitmap = NSBitmapImageRep(data: imageData),
               let pngData = bitmap.representation(using: .png, properties: [:]),
               let image = NSImage(data: pngData) {
                onImagePaste?(image, pngData)
                return
            }
        }

        // Fall through to default text paste
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isEscape = event.keyCode == 53
        let isUp = event.keyCode == 126
        let isDown = event.keyCode == 125
        let isTab = event.keyCode == 48
        let hasShift = event.modifierFlags.contains(.shift)
        let hasCommand = event.modifierFlags.contains(.command)

        if menuActive() {
            if isUp { onMenuMove(-1); return }
            if isDown { onMenuMove(1); return }
            if isEscape { onMenuCancel(); return }
            if (isReturn && !hasShift) || (isTab && !hasShift) {
                if let replacement = onMenuCommit() {
                    let fullRange = NSRange(location: 0, length: (string as NSString).length)
                    if shouldChangeText(in: fullRange, replacementString: replacement) {
                        replaceCharacters(in: fullRange, with: replacement)
                        didChangeText()
                        setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
                    }
                    return
                }
            }
        }

        if isReturn && hasCommand {
            onReturn?()
            return
        }
        if isReturn && sendOnReturn && !hasShift {
            onReturn?()
            return
        }
        // Escape = interrupt / dismiss
        if isEscape {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
