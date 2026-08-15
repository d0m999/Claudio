import ClaudioCore
import Foundation

@MainActor
func runClaudioVersionSuites() {
    suite("ClaudioVersion embeds the development default or a strict injected release version") {
        let version = ClaudioVersion.current
        let releasePattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#
        expect(
            version == "0.0.0-dev"
                || version.range(of: releasePattern, options: .regularExpression) != nil,
            "unexpected embedded Claudio version: \(version)")
    }
}
