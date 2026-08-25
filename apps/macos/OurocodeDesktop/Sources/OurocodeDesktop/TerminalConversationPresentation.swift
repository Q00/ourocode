import Foundation

/// Renderer-only projection of Ghostty's OSC 133 metadata. The broker keeps a
/// single canonical terminal model; this policy merely marks cells so the GPU
/// can make command turns easier to scan without building a parallel chat log.
enum TerminalConversationPresentation {
    static let promptRowFlag: UInt32 = 1 << 7
    static let inputFlag: UInt32 = 1 << 8
    static let promptFlag: UInt32 = 1 << 9
    /// The first row of a command turn. Continuation rows keep the same quiet
    /// background, but only the first row receives the separator in Metal.
    static let promptStartRowFlag: UInt32 = 1 << 10

    static func surfaceFlags(rowSemantic: UInt32, cellSemantic: UInt32) -> UInt32 {
        var flags: UInt32 = 0
        if rowSemantic == 1 {
            flags |= promptRowFlag | promptStartRowFlag
        } else if rowSemantic == 2 {
            flags |= promptRowFlag
        }
        if cellSemantic == 1 { flags |= inputFlag }
        if cellSemantic == 2 { flags |= promptFlag }
        return flags
    }
}
