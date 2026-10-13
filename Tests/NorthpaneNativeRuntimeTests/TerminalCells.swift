import Foundation
import SwiftTerm
import Testing
@testable import NorthpaneNativeRuntime

struct Cell: Equatable {
    let text: String
    let width: Int8
    let attribute: Attribute
}

func cells(_ terminal: Terminal) -> [Cell] {
    (0..<terminal.rows).flatMap { row in
        (0..<terminal.cols).map { column in
            let cell = terminal.getCharData(col: column, row: row)!
            let character = terminal.getCharacter(for: cell)
            return Cell(text: character == "\0" ? " " : String(character), width: cell.width, attribute: cell.attribute)
        }
    }
}
