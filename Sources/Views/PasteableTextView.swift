import SwiftUI
import AppKit

struct PasteableTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var onReturn: () -> Void
    var onEscape: () -> Void
    var onImagePaste: (NSImage, Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.onImagePaste = onImagePaste
        textView.onReturn = onReturn
        textView.onEscape = onEscape
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
        }
    }
}

final class ImagePasteTextView: NSTextView {
    var onImagePaste: ((NSImage, Data) -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

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
        // Return without shift = send
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            onReturn?()
            return
        }
        // Escape = interrupt
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
