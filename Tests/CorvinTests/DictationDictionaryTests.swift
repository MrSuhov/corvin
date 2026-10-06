import XCTest
@testable import Corvin

/// The dictation dictionary as text: what counts as a term, what the shipped
/// example yields, and when dictation gets no prompt at all.
final class DictationDictionaryTests: XCTestCase {

    private let exampleTerms = ["Корвин", "деплой", "вайбкодинг"]

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DictationDictionary.textKey)
        UserDefaults.standard.removeObject(forKey: DictationDictionary.enabledKey)
        super.tearDown()
    }

    func testCommentLinesAreNotTerms() {
        let text = """
        # names first
          # indented note
        Корвин
        деплой, вайбкодинг; GigaAM

        """
        XCTAssertEqual(DictationDictionary.terms(from: text), ["Корвин", "деплой", "вайбкодинг", "GigaAM"])
    }

    func testRepeatsAreDroppedFirstSpellingWins() {
        XCTAssertEqual(TermList.parse("Корвин\nкорвин\n  \nКОРВИН,деплой"), ["Корвин", "деплой"])
    }

    /// Every language ships the same three words under its own instructions.
    func testExampleInEveryLanguageYieldsTheThreeWords() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Resources")
        for language in ["en", "ru", "es"] {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            let example = try XCTUnwrap(strings["dictation.dictionary.example"], language)
            XCTAssertEqual(DictationDictionary.terms(from: example), exampleTerms, language)
        }
    }

    func testOffOrEmptyGivesNoTerms() {
        DictationDictionary.text = "Корвин"
        DictationDictionary.isEnabled = false
        XCTAssertNil(DictationDictionary.activeTerms)

        DictationDictionary.isEnabled = true
        XCTAssertEqual(DictationDictionary.activeTerms, ["Корвин"])

        DictationDictionary.text = "# only a note\n\n"
        XCTAssertNil(DictationDictionary.activeTerms)
    }

    func testOffByDefault() {
        XCTAssertFalse(DictationDictionary.isEnabled)
    }
}
