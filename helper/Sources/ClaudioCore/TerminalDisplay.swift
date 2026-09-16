import Foundation

/// Render an untrusted identifier as inert terminal text. Truncation happens at Character
/// boundaries, while scalar and output-byte ceilings also bound unusually long graphemes.
public func terminalSafePackID(_ value: String) -> String {
    let maxCharacters = 64
    let maxScalars = 256
    let maxBytes = 256
    var rendered = ""
    var scalarCount = 0
    var wasTruncated = false

    for (characterIndex, character) in value.enumerated() {
        if characterIndex >= maxCharacters {
            wasTruncated = true
            break
        }
        var segment = ""
        for scalar in character.unicodeScalars {
            if scalarCount >= maxScalars {
                wasTruncated = true
                break
            }
            scalarCount += 1
            let code = scalar.value
            if CharacterSet.controlCharacters.contains(scalar)
                || (0x202A...0x202E).contains(code)
                || (0x2066...0x206F).contains(code)
                || code == 0x200E || code == 0x200F || code == 0x061C
            {
                segment += "\\u{\(String(code, radix: 16, uppercase: true))}"
            } else {
                segment.unicodeScalars.append(scalar)
            }
        }
        if wasTruncated { break }
        if rendered.utf8.count + segment.utf8.count > maxBytes - 3 {
            wasTruncated = true
            break
        }
        rendered += segment
    }
    return wasTruncated ? rendered + "…" : rendered
}
