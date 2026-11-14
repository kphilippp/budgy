import SwiftUI
import UIKit

/// A row of color circles for choosing the theme color.
struct ThemeSwatches: View {
    @Binding var selection: AppTheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    withAnimation(Motion.quick) { selection = theme }
                } label: {
                    Pebble(seed: theme.rawValue.stableHash)
                        .fill(theme.color)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Pebble(seed: theme.rawValue.stableHash)
                                .stroke(Color.ink.opacity(selection == theme ? 0.7 : 0), lineWidth: 2)
                                .padding(-5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
    }
}

/// The Home Screen icons Budgy can switch between.
enum AppIconOption: String, CaseIterable, Identifiable {
    case teal, midnight, sunset, ocean, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: "Budgy Teal"
        case .midnight: "Midnight"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .mono: "Mono"
        }
    }

    /// Asset catalog name of the alternate icon; nil means the primary icon.
    var iconName: String? {
        switch self {
        case .teal: nil
        case .midnight: "AppIcon-Midnight"
        case .sunset: "AppIcon-Sunset"
        case .ocean: "AppIcon-Ocean"
        case .mono: "AppIcon-Mono"
        }
    }

    var previewImage: String {
        "IconPreview-\(rawValue.prefix(1).uppercased() + rawValue.dropFirst())"
    }

    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == name } ?? .teal
    }
}

struct AppIconPicker: View {
    @State private var selected = AppIconOption.current
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        Task { await choose(option) }
                    } label: {
                        VStack(spacing: 8) {
                            Image(option.previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 76, height: 76)
                                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(.tint, lineWidth: selected == option ? 3 : 0)
                                        .padding(-5)
                                }
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            Text(option.title)
                                .font(.caption.weight(selected == option ? .semibold : .regular))
                                .foregroundStyle(selected == option ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) icon")
                    .accessibilityAddTraits(selected == option ? .isSelected : [])
                }
            }
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.negative)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ option: AppIconOption) async {
        guard option != selected, UIApplication.shared.supportsAlternateIcons else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(option.iconName)
            withAnimation { selected = option }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change the icon: \(error.localizedDescription)"
        }
    }
}
