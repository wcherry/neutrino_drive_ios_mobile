import SwiftUI

struct FilesView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Files")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Files")
    }
}

#Preview {
    FilesView()
}
