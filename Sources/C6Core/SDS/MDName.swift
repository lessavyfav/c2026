import Foundation

/// The Machinedrum's 4-character sample names (SPS-1UW, MD OS 1.62+), sent as message 0x73.
public enum MDName {
    /// Characters the MD can show: A–Z, 0–9, space, common punctuation, and Å Ä Ö.
    static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -+.!#&()*/=?_ÅÄÖ")

    /// Upper-cases, drops what the MD can't show, and limits to 4 characters (no padding).
    public static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { allowed.contains($0) }.prefix(4))
    }

    /// A suggested MD name for a file: the name part of "MD26 MOUF.wav" (C2026's received-sample
    /// names) so round trips keep their name; otherwise C6's rule (first 3 + last character,
    /// so "snare01" → "SNA1").
    public static func suggest(forFileName fileName: String) -> String {
        let base = SDSMessage.baseName(ofFileName: fileName)
        if let r = base.range(of: #"^MD\d{1,2}\s+(.+)$"#, options: .regularExpression) {
            let rest = base[r].drop { $0 != " " }.drop { $0 == " " }
            let n = normalize(String(rest))
            if !n.isEmpty { return n }
        }
        return normalize(SDSMessage.spsName(fromBaseName: base)).trimmingCharacters(in: .whitespaces)
    }
}
