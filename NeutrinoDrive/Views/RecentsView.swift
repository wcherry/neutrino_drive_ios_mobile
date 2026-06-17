import SwiftUI

struct RecentsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Recents")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Recents")
    }
}

#Preview {
    RecentsView()
}
