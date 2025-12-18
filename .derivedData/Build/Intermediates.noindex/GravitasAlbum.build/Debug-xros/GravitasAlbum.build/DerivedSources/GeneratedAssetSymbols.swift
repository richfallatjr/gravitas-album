import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "AppIcon" asset catalog resource namespace.
    enum AppIcon {

        /// The "AppIcon/Middle" asset catalog resource namespace.
        enum Middle {

            /// The "AppIcon/Middle/Content" asset catalog image resource.
            static let content = DeveloperToolsSupport.ImageResource(name: "AppIcon/Middle/Content", bundle: resourceBundle)

        }

        /// The "AppIcon/Back" asset catalog resource namespace.
        enum Back {

            /// The "AppIcon/Back/Content" asset catalog image resource.
            static let content = DeveloperToolsSupport.ImageResource(name: "AppIcon/Back/Content", bundle: resourceBundle)

        }

        /// The "AppIcon/Front" asset catalog resource namespace.
        enum Front {

            /// The "AppIcon/Front/Content" asset catalog image resource.
            static let content = DeveloperToolsSupport.ImageResource(name: "AppIcon/Front/Content", bundle: resourceBundle)

        }

    }

    /// The "gravitas-logo-alone" asset catalog image resource.
    static let gravitasLogoAlone = DeveloperToolsSupport.ImageResource(name: "gravitas-logo-alone", bundle: resourceBundle)

}

