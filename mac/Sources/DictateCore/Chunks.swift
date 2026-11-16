import Foundation

/// A long take is cut at pauses while it is still being recorded, and each piece goes out at once:
/// by the time the hotkey is let go only the last stretch is left to transcribe.
public enum Chunks {
    public static let minSeconds: Double = 20
    public static let pauseMs = 500

    /// Where to cut a segment: the middle of its first pause after `minSeconds`, or nil when there is none yet.
    /// The silence threshold follows the segment's own noise floor, 12 dB over it, never above the fixed one.
    public static func findCut(
        _ segment: [Float], sampleRate: Double, minSeconds: Double = minSeconds, pauseMs: Int = pauseMs
    ) -> Int? {
        let window = max(1, Int(sampleRate) / 100)  // 10 ms
        let first = Int(minSeconds * 100), need = max(1, pauseMs / 10)
        let count = segment.count / window
        guard count >= first + need else { return nil }
        let levels = (0..<count).map { rms(segment[($0 * window)..<(($0 + 1) * window)]) }
        guard let peak = levels.max(), peak >= 0.003 else { return nil }  // silence throughout: nothing to split
        let floor = levels.sorted()[count / 10]
        let threshold = min(0.012, max(floor * 4, 0.002))
        var run = 0
        for i in first..<count {
            run = levels[i] < threshold ? run + 1 : 0
            if run == need { return (i + 1 - need / 2) * window }
        }
        return nil
    }

    /// The pieces' texts in order; empty pieces (a cough, a breath) leave no double spaces.
    public static func join(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum Vocabulary {
    public static let maxLength = 60

    /// What the worker takes as a dictionary term: one line, no comma (the prompt is a comma-separated list).
    /// Length in UTF-16 units, as the worker counts it.
    public static func isTerm(_ text: String?) -> Bool {
        guard let term = text?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty,
            term.utf16.count <= maxLength
        else { return false }
        return !term.unicodeScalars.contains { $0 == "," || CharacterSet.controlCharacters.contains($0) }
    }
}
