import Foundation

do {
    let checks = try runProtocolSafetyChecks()
    print("\(checks) protocol and movement safety checks passed")
} catch {
    fputs("Protocol safety check failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
