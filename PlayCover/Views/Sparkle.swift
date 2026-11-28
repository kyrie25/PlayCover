//
//  Sparkle.swift
//  PlayCover
//
//  Created by Andrew Glaze on 7/17/22.
//  Copied from https://sparkle-project.org/documentation/programmatic-setup/
//

import Sparkle
import SwiftUI

// This view model class manages Sparkle's updater and publishes when new updates are allowed to be checked
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController?
    let manualUpdatesOnly = Bundle.main.object(forInfoDictionaryKey: "PlayCoverManualUpdatesOnly") as? Bool == true
    static let nightlyBuildsURL = URL(
        string: "https://github.com/kyrie25/PlayCover/actions/workflows/2.nightly_release.yml?query=branch%3Adevelop")

    @Published var canCheckForUpdates = false

    var automaticallyCheckForUpdates: Bool {
        get {
            updaterController?.updater.automaticallyChecksForUpdates ?? false
        }
        set(newValue) {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    init() {
        guard !manualUpdatesOnly else {
            updaterController = nil
            return
        }
        // If you want to start the updater manually, pass false to startingUpdater and call .startUpdater() later
        // This is where you can also pass an updater delegate if you need one
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        updaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if automaticallyCheckForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

// This additional view is needed for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more information
struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        if updaterViewModel.manualUpdatesOnly, let url = UpdaterViewModel.nightlyBuildsURL {
            Link(destination: url) {
                Label("Download Nightly Builds", systemImage: "arrow.down.circle")
            }
        } else {
            Button(NSLocalizedString("menubar.checkForUpdates", comment: ""),
                   systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                   action: updaterViewModel.checkForUpdates)
                .disabled(!updaterViewModel.canCheckForUpdates)
        }
    }
}
