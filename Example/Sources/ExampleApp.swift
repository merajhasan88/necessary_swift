// The Necessary SDK against its sample backends (../backend), section by section: the installation,
// the scan with every measurement it sent, an account, requests with and without the person's
// approval, and requests a backend must refuse. Setup.swift makes the DeviceTrust, SampleAPI.swift
// signs what the app sends, Measurements.swift reads a scan; TrustView.swift is the screen.
import SwiftUI

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            TrustView()
        }
    }
}
