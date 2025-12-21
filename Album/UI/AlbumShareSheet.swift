import SwiftUI

#if canImport(UIKit)
import UIKit

struct AlbumShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((UIActivity.ActivityType?, Bool, [Any]?, Error?) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        controller.completionWithItemsHandler = { activity, completed, returnedItems, error in
            onComplete?(activity, completed, returnedItems, error)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
