import SwiftUI

struct OfflineView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Offline")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Offline")
    }
}

#Preview {
    OfflineView()
}
