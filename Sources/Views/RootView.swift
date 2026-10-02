import SwiftUI

/// Tab container: entry screen + history of this app's entries.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Eintragen", systemImage: "plus.circle.fill") {
                ContentView()
            }
            Tab("Verlauf", systemImage: "list.bullet.rectangle") {
                HistoryView()
            }
        }
    }
}

#Preview {
    RootView()
}
