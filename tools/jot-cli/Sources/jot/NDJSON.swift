import Foundation

/// One JSON object per line on stdout, flushed per line — the machine
/// streaming contract (design doc §15). Field set is additive-only: consumers
/// (Call Assist) parse `{"type":"final","text":"..."}` and must tolerate new
/// fields, never removed ones.
enum NDJSON {
    private struct Line: Encodable {
        let type: String
        let text: String
    }

    static func emitFinal(_ text: String) {
        emit(Line(type: "final", text: text))
    }

    private static func emit(_ line: Line) {
        guard let data = try? JSONEncoder().encode(line),
              let string = String(data: data, encoding: .utf8)
        else { return }
        print(string)
        fflush(stdout)
    }
}
