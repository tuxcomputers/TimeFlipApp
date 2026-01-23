import AppKit

enum ActivityIconLoader {
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let directURL = Bundle.module.url(forResource: trimmed, withExtension: "svg")
        let nestedURL = Bundle.module.url(forResource: trimmed, withExtension: "svg", subdirectory: "Icons/Activities")
        guard let url = directURL ?? nestedURL else {
            return nil
        }
        guard let rep = NSImageRep(contentsOf: url) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
