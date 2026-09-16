import Foundation

#if DEBUG
/// Deterministic test seam for the process-image resolver. It deliberately has no `argv[0]`
/// parameter: a bare command is not a source of process identity.
public func currentExecutablePathForTesting(
    procPIDPath: String? = nil,
    procPIDCString: [CChar]? = nil,
    fallbackPath: String? = nil,
    relativeTo currentDirectory: URL? = nil
) throws -> URL {
    let rawPath = procPIDCString.flatMap(decodedExecutableCString) ?? procPIDPath ?? fallbackPath
    guard let rawPath else {
        throw ExecutablePathError.processImageUnavailable
    }
    return try validatedExecutablePath(rawPath, relativeTo: currentDirectory)
}
#endif
