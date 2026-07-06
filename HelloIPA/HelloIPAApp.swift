import SwiftUI

@main
struct HelloIPAApp: App {
    var body: some Scene {
        WindowGroup {
            Text("hello")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
    }
}
