import SwiftUI
import UIKit

extension Color {
    /// The app's accent color (teal blue), lighter in dark mode. Same values as AccentColor in the asset catalog.
    static let brand = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.255, green: 0.690, blue: 0.780, alpha: 1)
            : UIColor(red: 0.067, green: 0.478, blue: 0.612, alpha: 1)
    })
}
