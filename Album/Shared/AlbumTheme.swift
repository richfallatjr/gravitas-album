import SwiftUI

public enum AlbumTheme: String, Codable, Sendable {
    case dark

    public var palette: AlbumThemePalette {
        let readAccent = Color(red: 169.0 / 255.0, green: 220.0 / 255.0, blue: 118.0 / 255.0)
        let historyAccent = Color(red: 171.0 / 255.0, green: 157.0 / 255.0, blue: 242.0 / 255.0)
        let openAccent = Color(red: 255.0 / 255.0, green: 97.0 / 255.0, blue: 136.0 / 255.0)
        let toggleAccent = Color(red: 255.0 / 255.0, green: 216.0 / 255.0, blue: 102.0 / 255.0)
        let copyAccent = Color(red: 120.0 / 255.0, green: 220.0 / 255.0, blue: 232.0 / 255.0)

        return AlbumThemePalette(
            cardBackground: Color(.sRGB, white: 0.10, opacity: 0.92),
            cardBorder: Color.white.opacity(0.16),
            primaryText: .white,
            secondaryText: Color.white.opacity(0.72),
            captionText: Color.white.opacity(0.60),
            overlayText: Color.white.opacity(0.70),
            navBackground: Color(.sRGB, white: 0.08, opacity: 0.92),
            navBorder: Color.white.opacity(0.18),
            navIconActive: .white,
            navIconDisabled: Color.white.opacity(0.38),
            panelBackground: Color(.sRGB, white: 0.12, opacity: 0.94),
            panelPrimaryText: .white,
            panelSecondaryText: Color.white.opacity(0.72),
            readButtonColor: readAccent,
            historyButtonColor: historyAccent,
            openButtonColor: openAccent,
            toggleFillColor: toggleAccent,
            toggleIconColor: .black,
            copyButtonFill: copyAccent,
            copyIconColor: .black,
            buttonLabelOnColor: .black
        )
    }
}

public struct AlbumThemePalette: Sendable {
    public let cardBackground: Color
    public let cardBorder: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let captionText: Color
    public let overlayText: Color
    public let navBackground: Color
    public let navBorder: Color
    public let navIconActive: Color
    public let navIconDisabled: Color
    public let panelBackground: Color
    public let panelPrimaryText: Color
    public let panelSecondaryText: Color
    public let readButtonColor: Color
    public let historyButtonColor: Color
    public let openButtonColor: Color
    public let toggleFillColor: Color
    public let toggleIconColor: Color
    public let copyButtonFill: Color
    public let copyIconColor: Color
    public let buttonLabelOnColor: Color

    public init(
        cardBackground: Color,
        cardBorder: Color,
        primaryText: Color,
        secondaryText: Color,
        captionText: Color,
        overlayText: Color,
        navBackground: Color,
        navBorder: Color,
        navIconActive: Color,
        navIconDisabled: Color,
        panelBackground: Color,
        panelPrimaryText: Color,
        panelSecondaryText: Color,
        readButtonColor: Color,
        historyButtonColor: Color,
        openButtonColor: Color,
        toggleFillColor: Color,
        toggleIconColor: Color,
        copyButtonFill: Color,
        copyIconColor: Color,
        buttonLabelOnColor: Color
    ) {
        self.cardBackground = cardBackground
        self.cardBorder = cardBorder
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.captionText = captionText
        self.overlayText = overlayText
        self.navBackground = navBackground
        self.navBorder = navBorder
        self.navIconActive = navIconActive
        self.navIconDisabled = navIconDisabled
        self.panelBackground = panelBackground
        self.panelPrimaryText = panelPrimaryText
        self.panelSecondaryText = panelSecondaryText
        self.readButtonColor = readButtonColor
        self.historyButtonColor = historyButtonColor
        self.openButtonColor = openButtonColor
        self.toggleFillColor = toggleFillColor
        self.toggleIconColor = toggleIconColor
        self.copyButtonFill = copyButtonFill
        self.copyIconColor = copyIconColor
        self.buttonLabelOnColor = buttonLabelOnColor
    }
}
