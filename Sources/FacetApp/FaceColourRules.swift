import AppKit

/// What one face should light up in, read at the moment it is needed.
///
/// **A face, not a category.** What the cube is told is "facet 3 is this colour", so the category is carried only to
/// put a name on the log row: nothing downstream branches on it, and a face holding nothing is as complete an answer
/// as a face holding Meeting.
struct FaceColour: Equatable {
    let face: Int
    /// The category on the face, for the row that says what went out. `nil` for a face holding nothing.
    let categoryName: String?
    /// The colour to light it in, or `nil` for **off**. See `FaceColourRules.channels`, which is where `nil` becomes
    /// black and where the reasoning for that lives.
    let colour: NSColor?
}

/// Lighting a face on the cube: the bytes `0x11` carries, and what a category's colour becomes on the way there.
///
/// Its own type rather than another case in `DeviceCommandRules`, for `DoubleTapRules`' reason: the command is one
/// part of it, and the scaling and the fallback are the parts that actually cost something to get right.
enum FaceColourRules {
    /// `0x11`, the vendor's set-colour-for-a-facet command.
    static let write: UInt8 = 0x11

    /// The faces there are to light.
    ///
    /// **`DeviceFaceRules.reported` rather than a 12 written again**, because it is the same fact: 1 to 12 is what a
    /// cube reports and what a cube can be told about. The app's own face 13 is deliberately outside it -- manual
    /// mode's face exists because no cube is there, so there is nothing to light.
    static let faces = DeviceFaceRules.reported

    /// The command: `0x11 NN RR RR GG GG BB BB`, sixteen bits per channel, big-endian.
    ///
    /// **Eight bytes, and the two-byte channels are the part worth checking.** `docs/TimeFlip2 BLE Protocol v4.3.md`
    /// Tab. 1 spells the layout out, and the archive's `setFaceColor` writes exactly these eight, high byte first.
    /// Hex is 8 bits per channel and the command takes 16, so a colour that went out un-scaled would light every face
    /// at roughly nothing rather than at the colour asked for.
    static func command(for wanted: FaceColour) -> Data {
        let (red, green, blue) = channels(of: wanted.colour)
        var bytes: [UInt8] = [write, UInt8(clamping: wanted.face)]
        for channel in [red, green, blue] {
            bytes.append(UInt8(truncatingIfNeeded: channel >> 8))
            bytes.append(UInt8(truncatingIfNeeded: channel))
        }
        return Data(bytes)
    }

    /// The three channels as the command carries them: 0 to 65535 each, scaled from sRGB.
    ///
    /// **`nil` is black, and black is the only way to say off.** `0x11` takes an RGB triple with no separate enable,
    /// so a face whose category has no colour -- or which holds no category at all -- is sent all-zero rather than
    /// left as it was. That is the archive's rule and its reasoning is what makes it the right one: clearing a colour
    /// is an instruction, and leaving the old one lit would make *None* mean *unchanged*, which is invisible on the
    /// cube and impossible to undo from the window.
    ///
    /// **Converted to sRGB before it is read**, because the same three numbers mean different colours in different
    /// spaces and the palette's own hexes are sRGB (`ColourStore`). A colour that would not convert is treated as off,
    /// which is the honest answer: an unlit face is wrong in a way somebody can see, and a channel read out of the
    /// wrong space is wrong in a way nobody can.
    static func channels(of colour: NSColor?) -> (red: UInt16, green: UInt16, blue: UInt16) {
        guard let sRGB = colour?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        func scale(_ channel: CGFloat) -> UInt16 {
            UInt16(clamping: Int((channel * 65_535).rounded()))
        }
        return (scale(sRGB.redComponent), scale(sRGB.greenComponent), scale(sRGB.blueComponent))
    }

    /// One face put into words, for the row that says what went out.
    ///
    /// **Both forms of the colour, which is the archive's own reason for logging both**: the hex is what somebody can
    /// compare against the palette, and the sixteen-bit triple is what actually went on the wire, so a scaling problem
    /// is visible rather than inferred. A face lighting up wrong can be checked against exactly what was sent for it.
    ///
    /// No apostrophes and no quotation marks, per `CLAUDE.md`: these rows are read back out of `debug_log` by SQL
    /// `LIKE` patterns.
    static func describe(_ wanted: FaceColour) -> String {
        let (red, green, blue) = channels(of: wanted.colour)
        let triple = String(format: "%04x,%04x,%04x", Int(red), Int(green), Int(blue))
        return "face \(wanted.face) \(wanted.categoryName ?? "no category") \(hex(of: wanted.colour)) as rgb16 \(triple)"
    }

    /// `#rrggbb`, or `off` where there is no colour. Eight bits a channel, which is what the palette stores and what
    /// somebody would compare against `database/005_colour.sql`.
    static func hex(of colour: NSColor?) -> String {
        guard let sRGB = colour?.usingColorSpace(.sRGB) else { return "off" }
        func scale(_ channel: CGFloat) -> Int {
            max(0, min(255, Int((channel * 255).rounded())))
        }
        return String(
            format: "#%02x%02x%02x",
            scale(sRGB.redComponent), scale(sRGB.greenComponent), scale(sRGB.blueComponent)
        )
    }
}
