import SwiftUI

struct KeyboardLanguagesView: View {
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        List {
            Section(footer: Text("settings.language.keyboardHint".localized)) {
                ForEach(KeyboardLanguage.all) { language in
                    HStack {
                        Text(language.localizedName)
                        Spacer()
                        if localization.isKeyboardLanguageEnabled(language.code) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        localization.toggleKeyboardLanguage(language.code)
                    }
                }
            }
        }
        .navigationTitle("settings.language.keyboardLanguages".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}
