import SwiftUI

@main
struct DiskDeduperApp: App {
    @StateObject private var scanner = DuplicateScanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
    }
}
