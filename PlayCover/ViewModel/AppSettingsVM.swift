//
//  AppSettingsVM.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/08/15.
//

import Foundation

class AppSettingsVM: ObservableObject {
    let app: PlayApp
    @Published var settings: AppSettings
    @Published private(set) var runtimeMove: RuntimeDataMigration.Progress?

    init(app: PlayApp) {
        self.app = app
        settings = app.settings
    }

    @MainActor
    func switchRuntime(to enabled: Bool) async throws {
        guard runtimeMove == nil, enabled != settings.settings.useIsolatedRuntime else { return }
        runtimeMove = .preparing
        let (updates, continuation) = AsyncStream<RuntimeDataMigration.Progress>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await progress in updates {
                if Task.isCancelled { break }
                runtimeMove = progress
            }
        }
        defer {
            continuation.finish()
            observer.cancel()
            runtimeMove = nil
        }
        try await IsolatedRuntime.setEnabled(enabled, for: app) { continuation.yield($0) }
        settings = app.settings
    }
}
