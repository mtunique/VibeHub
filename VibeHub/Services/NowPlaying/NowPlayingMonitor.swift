#if !APP_STORE

import Combine
import SwiftUI

@MainActor
class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    @Published var state: NowPlayingState = .empty

    private var cancellable: AnyCancellable?

    private init() {
        cancellable = NowPlayingService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state = newState
            }
    }

    func start() {
        Task { await NowPlayingService.shared.start() }
    }

    func stop() {
        Task { await NowPlayingService.shared.stop() }
    }

    func togglePlayPause() {
        Task { await NowPlayingService.shared.togglePlayPause() }
    }

    func next() {
        Task { await NowPlayingService.shared.next() }
    }

    func previous() {
        Task { await NowPlayingService.shared.previous() }
    }
}

#endif
