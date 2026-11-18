import SwiftUI

struct StorefrontPicker: View {
    @Binding var country: String

    static let codes = ["US", "CN", "HK", "TW", "JP", "KR", "SG", "IN", "AU", "CA",
                        "GB", "DE", "FR", "IT", "ES", "BR", "MX"]

    static var defaultCountry: String {
        supportedCountry(Locale.current.region?.identifier ?? "US", fallback: "US")
    }

    static func supportedCountry(_ code: String, fallback: String) -> String {
        codes.contains(code) ? code : fallback
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    var body: some View {
        Picker("Storefront", selection: $country) {
            ForEach(Self.codes, id: \.self) { code in
                Text(Self.name(code)).tag(code)
            }
        }
        .fixedSize()
    }
}
