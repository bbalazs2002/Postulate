import XCTest
import SwiftTreeSitter
import TreeSitterPostulateParser

final class TreeSitterPostulateParserTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_postulate_parser())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading PostulateParser grammar")
    }
}
