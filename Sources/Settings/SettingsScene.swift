import SwiftUI

struct JotSettings: Scene {
    var body: some Scene {
        Settings {
            VStack(spacing: 16) {
                Image(systemName: "gearshape")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Settings coming soon")
                    .font(.headline)
            }
            .frame(width: 460, height: 260)
            .padding()
        }
    }
}
