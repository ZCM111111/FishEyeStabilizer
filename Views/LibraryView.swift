import SwiftUI
import PhotosUI

// MARK: - 相册视图 (simplified for CI)

struct LibraryView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var processingVM: ProcessingViewModel

    @State private var showProcessing = false

    var body: some View {
        NavigationStack {
            VStack {
                if libraryVM.videos.isEmpty {
                    Text("相册中没有视频")
                        .foregroundColor(.gray)
                } else {
                    List(libraryVM.videos) { video in
                        Button(video.formattedDuration) {
                            libraryVM.selectVideo(video)
                            showProcessing = true
                        }
                    }
                }
            }
            .navigationTitle("相册")
            .navigationDestination(isPresented: $showProcessing) {
                if let video = libraryVM.selectedVideo {
                    ProcessingView(viewModel: processingVM, sourceVideo: video)
                }
            }
        }
    }
}
