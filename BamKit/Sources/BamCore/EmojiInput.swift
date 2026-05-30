/// Pure helpers for turning raw text-field contents (from the system emoji
/// viewer or typing) into a single device-icon glyph.
public enum EmojiInput {
    /// The newest user-perceived character in `s`, or nil if `s` is empty.
    /// A grapheme cluster (e.g. a flag or skin-toned emoji) counts as one.
    public static func lastGrapheme(of s: String) -> String? {
        s.last.map(String.init)
    }
}
