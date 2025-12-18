import SwiftUI

public struct AlbumPopOutAssetView: View {
    public let assetID: String
    @EnvironmentObject private var model: AlbumModel

    public init(assetID: String) {
        self.assetID = assetID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AlbumMediaPane(assetID: assetID)
        }
        .padding(18)
        .onAppear {
            model.appendPoppedAsset(assetID)
        }
        .onDisappear {
            model.removePoppedAsset(assetID)
        }
    }
}
