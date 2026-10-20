// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

public enum StartOutcome: Equatable, Sendable {
    case started(SessionID)
    case rejected(reason: String)
}

public enum StopOutcome: Equatable, Sendable {
    case stopped(SessionID)
    case rejected(reason: String)
}

public actor SessionCoordinator {
    private enum State: Equatable {
        case idle
        case recording(SessionID)
    }
    private var state: State = .idle

    public init() {}

    public var currentSession: SessionID? {
        if case .recording(let id) = state { return id }
        return nil
    }

    public func start() -> StartOutcome {
        switch state {
        case .idle:
            let id = SessionID.make()
            state = .recording(id)
            return .started(id)
        case .recording:
            return .rejected(reason: "already recording")
        }
    }

    public func stop() -> StopOutcome {
        switch state {
        case .recording(let id):
            state = .idle
            return .stopped(id)
        case .idle:
            return .rejected(reason: "not recording")
        }
    }
}
