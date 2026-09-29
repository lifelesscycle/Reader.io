/// Splits chapter text into sentences for per-sentence TTS synthesis.
///
/// A naive split on '.', '!', '?' breaks badly on abbreviations ("Dr. Smith
/// walked in.") and decimal numbers ("It cost 3.14 dollars."). This splitter
/// protects known abbreviation patterns and decimals before splitting, then
/// restores them afterward.
class SentenceSplitter {
  // Common abbreviations that end in a period but do NOT end a sentence.
  // Matched case-sensitively, word-boundary-aware, at the point right
  // before the period.
  static const _abbreviations = [
    'Mr', 'Mrs', 'Ms', 'Dr', 'Prof', 'Sr', 'Jr', 'St',
    'vs', 'etc', 'e.g', 'i.e', 'Rev', 'Gen', 'Sgt', 'Capt', 'Lt', 'Col',
    'Ave', 'Blvd', 'Inc', 'Ltd', 'Co', 'Corp', 'Ph.D', 'M.D',
    'U.S', 'U.K', 'U.N', 'a.m', 'p.m', 'No', 'Fig', 'vol', 'pp',
  ];

  // Placeholder character unlikely to appear in normal prose, used to
  // temporarily mask periods we don't want treated as sentence boundaries.
  static const _maskChar = '\u0000';

  /// Splits [text] into a list of trimmed, non-empty sentences.
  static List<String> split(String text) {
    if (text.trim().isEmpty) return [];

    var masked = text;

    // Mask periods in known abbreviations (case-insensitive match on the
    // word, but we only mask the trailing period).
    for (final abbr in _abbreviations) {
      final pattern = RegExp(
        r'\b' + RegExp.escape(abbr) + r'\.',
        caseSensitive: true,
      );
      masked = masked.replaceAllMapped(
        pattern,
        (m) => '${m.group(0)!.substring(0, m.group(0)!.length - 1)}$_maskChar',
      );
    }

    // Mask periods inside decimal numbers (e.g. "3.14", "$19.99").
    masked = masked.replaceAllMapped(
      RegExp(r'(\d)\.(\d)'),
      (m) => '${m.group(1)}$_maskChar${m.group(2)}',
    );

    // Mask ellipses ("...") as a single non-splitting unit rather than
    // three separate sentence-ending periods.
    masked = masked.replaceAll('...', '\u0001');

    // Now split on '.', '!', '?' followed by whitespace + capital letter,
    // closing quote, or end of string.
    final sentenceEndPattern = RegExp(
      r'(?<=[.!?])(?=\s+[A-Z"' r"'" r']|\s*$)',
    );

    final rawParts = masked.split(sentenceEndPattern);

    // Restore masked characters.
    final sentences = rawParts
        .map((s) => s.replaceAll(_maskChar, '.').replaceAll('\u0001', '...'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return sentences;
  }
}