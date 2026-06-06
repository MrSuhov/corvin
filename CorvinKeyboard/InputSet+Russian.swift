import KeyboardKit

extension KeyboardLayout.InputSet {

    /// Russian ЙЦУКЕН layout
    static var russian: KeyboardLayout.InputSet {
        .init(rows: [
            .init(
                lowercased: "йцукенгшщзхъ",
                uppercased: "ЙЦУКЕНГШЩЗХЪ"
            ),
            .init(
                lowercased: "фывапролджэ",
                uppercased: "ФЫВАПРОЛДЖЭ"
            ),
            .init(
                lowercased: "ячсмитьбю",
                uppercased: "ЯЧСМИТЬБЮ"
            )
        ])
    }
}
