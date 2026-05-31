import Foundation

struct MediaRemoteSnapshotRefreshGate {
    private var inFlightRequestID: String?

    var isRefreshing: Bool {
        inFlightRequestID != nil
    }

    var activeRequestID: String? {
        inFlightRequestID
    }

    mutating func begin(requestID: String = UUID().uuidString) -> String? {
        guard inFlightRequestID == nil else {
            return nil
        }
        inFlightRequestID = requestID
        return requestID
    }

    @discardableResult
    mutating func finish(requestID: String?) -> Bool {
        guard let requestID, let inFlightRequestID else {
            return false
        }
        guard requestID == inFlightRequestID else {
            return false
        }
        self.inFlightRequestID = nil
        return true
    }

    mutating func reset() {
        inFlightRequestID = nil
    }
}
