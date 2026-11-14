import Foundation

/// Diagnostic identity for logs: domain/code only, never userInfo (failing
/// URLs carry tokens). Not a user-facing explanation — see
/// `describeUserFacingError`.
func describeTransportError(_ error: Error) -> String {
    let ns = error as NSError
    var description = "\(ns.domain)#\(ns.code)"
    if ns.domain == NSURLErrorDomain {
        let name = ns.code == NSURLErrorTimedOut
            ? "timedOut"
            : String(describing: URLError.Code(rawValue: ns.code))
        description += " \(name)"
    }
    return description
}

/// The reason a device request failed, for the UI. Relay failures keep their
/// own message — git's refusal from the host, or the distinct timeout /
/// offline / not-connected explanations — instead of collapsing to a bridged
/// type name (#423). Network errors get a readable reason with the diagnostic
/// code; nothing here echoes userInfo.
func describeUserFacingError(_ error: Error) -> String {
    if let relay = error as? RelayError {
        if case .rpc(let message) = relay {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The device refused the request" : trimmed
        }
        return relay.errorDescription ?? describeTransportError(error)
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        let reason = switch ns.code {
        case NSURLErrorTimedOut: "The connection timed out"
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: "No internet connection"
        case NSURLErrorNetworkConnectionLost: "The network connection was lost"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            "Couldn't reach the relay"
        default: "Network error"
        }
        return "\(reason) (\(describeTransportError(error)))"
    }
    if error is CancellationError { return "The request was cancelled" }
    if error is DecodingError { return "The device sent a reply this app can't read" }
    return describeTransportError(error)
}

/// Connectivity-aware variant: when the phone itself is offline, avoid
/// blaming the host with "The device is offline" and report the local link state.
func describeUserFacingError(_ error: Error, phoneOnline: Bool) -> String {
    if !phoneOnline {
        return "Phone is offline — waiting for connection"
    }
    return describeUserFacingError(error)
}
