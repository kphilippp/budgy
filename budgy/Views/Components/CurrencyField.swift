import SwiftUI
import UIKit

/// A money field that fills in from the right, like a card terminal:
/// typing 2, 0, 0, 0 shows $0.02 → $0.20 → $2.00 → $20.00 → $200.00. Backspace removes the last digit.
/// There are never placeholder zeros to delete, and the decimal point always stays put.
struct CurrencyField: View {
    var title: String
    @Binding var value: Double
    var alignment: TextAlignment = .trailing

    init(_ title: String, value: Binding<Double>, alignment: TextAlignment = .trailing) {
        self.title = title
        self._value = value
        self.alignment = alignment
    }

    var body: some View {
        TerminalCurrencyTextField(title: title, value: $value, alignment: alignment)
            .frame(minWidth: 96, minHeight: 22)
    }
}

private struct TerminalCurrencyTextField: UIViewRepresentable {
    var title: String
    @Binding var value: Double
    var alignment: TextAlignment

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.keyboardType = .numberPad
        textField.placeholder = title
        textField.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = title
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.value = $value
        context.coordinator.cents = Self.cents(from: value)
        textField.textAlignment = alignment == .leading ? .left : alignment == .center ? .center : .right
        textField.text = Self.format(cents: context.coordinator.cents)
    }

    private static func cents(from value: Double) -> Int64 {
        (max(value, 0) * 100).roundedToInt64
    }

    private static func format(cents: Int64) -> String {
        let digits = String(format: "%04lld", cents)
        let decimalIndex = digits.index(digits.endIndex, offsetBy: -2)
        let amount = "\(digits[..<decimalIndex]).\(digits[decimalIndex...])"
        let symbol = Locale.current.currencySymbol ?? "$"
        return symbol + amount
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var value: Binding<Double>
        var cents: Int64

        init(value: Binding<Double>) {
            self.value = value
            self.cents = TerminalCurrencyTextField.cents(from: value.wrappedValue)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                cents /= 10
            } else {
                let digits = string.compactMap(\.wholeNumberValue)
                guard !digits.isEmpty else { return false }
                for digit in digits where cents <= 9_999_999_999 {
                    cents = cents * 10 + Int64(digit)
                }
            }

            value.wrappedValue = Double(cents) / 100
            textField.text = TerminalCurrencyTextField.format(cents: cents)
            return false
        }
    }
}

private extension Double {
    var roundedToInt64: Int64 { Int64(rounded()) }
}

extension View {
    /// Dismisses the keyboard when tapping anywhere outside a text field.
    func dismissesKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}
