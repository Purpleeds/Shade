import SwiftUI
import UIKit

extension Binding where Value == [Float] {
    /// Bridges a 3-component 0...1 RGB array to a SwiftUI Color (for ColorPicker).
    var asColor: Binding<Color> {
        Binding<Color>(
            get: {
                let v = wrappedValue + [0, 0, 0]
                return Color(.sRGB, red: Double(v[0]), green: Double(v[1]), blue: Double(v[2]), opacity: 1)
            },
            set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                wrappedValue = [Float(r), Float(g), Float(b)].map { Swift.min(Swift.max($0, 0), 1) }
            }
        )
    }
}
