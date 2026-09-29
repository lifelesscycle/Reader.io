import 'dart:typed_data';
import 'package:epubx/epubx.dart' as epubx;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// A single parsed chapter: title + clean paragraph text (HTML/CSS stripped).
class ParsedChapter {
  final String title;
  final List<String> paragraphs;

  ParsedChapter({required this.title, required this.paragraphs});

  /// Full chapter text, paragraphs joined with blank lines — useful for
  /// character-count based time estimates and as TTS input before we
  /// split it sentence-by-sentence in the synthesis step (Day 2+).
  String get fullText => paragraphs.join('\n\n');

  int get characterCount => fullText.length;
}

/// A parsed book: title, author (if present), and its chapters in order.
class ParsedBook {
  final String title;
  final String? author;
  final List<ParsedChapter> chapters;

  ParsedBook({required this.title, this.author, required this.chapters});
}

/// Internal: one flattened TOC entry before we've resolved which spine
/// position it starts at.
class _TocEntry {
  final String? title;
  final String? contentFileName;
  _TocEntry({this.title, this.contentFileName});
}

/// Internal: a TOC entry after resolving its starting spine index.
class _ResolvedTocEntry {
  final String? title;
  final int? spineIndex;
  _ResolvedTocEntry({this.title, this.spineIndex});
}

/// Parses raw EPUB bytes into a [ParsedBook] with clean, TTS-ready text.
///
/// EPUB chapter content is XHTML. Many professionally-produced EPUBs split
/// a single logical chapter across several spine files (one per scene
/// break or page), with the table of contents only pointing at the first
/// file of each chapter. Trusting the TOC's chapter list alone (as
/// self-published single-file-per-chapter EPUBs allow) silently drops
/// every continuation file, which reads as the chapter cutting off partway
/// through.
///
/// To handle this correctly, chapters are reconstructed from the EPUB's
/// actual spine (its full linear reading order): the TOC is used only to
/// mark where each chapter *starts*, and every spine file up to the next
/// chapter's start is pulled in as that chapter's content.
Future<ParsedBook> parseEpub(Uint8List bytes) async {
  final epubBook = await epubx.EpubReader.readBook(bytes);

  // Build the spine's linear reading order as a list of file hrefs.
  final manifestItems = epubBook.Schema?.Package?.Manifest?.Items ?? [];
  final manifestById = <String, String>{
    for (final item in manifestItems)
      if (item.Id != null && item.Href != null) item.Id!: item.Href!,
  };
  final spineItems = epubBook.Schema?.Package?.Spine?.Items ?? [];
  final spineOrder = <String>[
    for (final item in spineItems)
      if (item.IdRef != null && manifestById.containsKey(item.IdRef))
        manifestById[item.IdRef]!,
  ];

  // Flatten the TOC's chapter list (including sub-chapters) in document
  // order, keeping each entry's title and which content file it points to.
  final flatToc = <_TocEntry>[];
  void flattenToc(List<epubx.EpubChapter>? chapterList) {
    if (chapterList == null) return;
    for (final chapter in chapterList) {
      final title = (chapter.Title?.trim().isNotEmpty ?? false)
          ? chapter.Title!.trim()
          : null;
      flatToc.add(
        _TocEntry(title: title, contentFileName: chapter.ContentFileName),
      );
      flattenToc(chapter.SubChapters);
    }
  }

  flattenToc(epubBook.Chapters);

  final htmlContent = epubBook.Content?.Html ?? {};
  final chapters = <ParsedChapter>[];

  if (spineOrder.isNotEmpty && flatToc.isNotEmpty) {
    // Resolve each TOC entry to its starting index in the spine.
    final resolved = <_ResolvedTocEntry>[];
    for (final entry in flatToc) {
      final fileName = entry.contentFileName;
      int? spineIndex;
      if (fileName != null) {
        var idx = spineOrder.indexOf(fileName);
        if (idx == -1) {
          // Fall back to matching by filename alone, in case of relative
          // path prefix differences between the TOC and manifest hrefs.
          final baseName = fileName.split('/').last;
          idx = spineOrder.indexWhere((h) => h.split('/').last == baseName);
        }
        spineIndex = idx == -1 ? null : idx;
      }
      resolved.add(_ResolvedTocEntry(title: entry.title, spineIndex: spineIndex));
    }

    // Drop entries that couldn't be resolved to a spine position, and
    // collapse consecutive entries resolving to the exact same starting
    // file (e.g. a sub-heading anchored within its parent's own file) —
    // keep the first title, since splitting there would only produce an
    // empty chapter.
    final usable = <_ResolvedTocEntry>[];
    for (final entry in resolved) {
      if (entry.spineIndex == null) continue;
      if (usable.isNotEmpty && usable.last.spineIndex == entry.spineIndex) {
        continue;
      }
      usable.add(entry);
    }

    for (var i = 0; i < usable.length; i++) {
      final start = usable[i].spineIndex!;
      final end =
          (i + 1 < usable.length) ? usable[i + 1].spineIndex! : spineOrder.length;

      final paragraphs = <String>[];
      for (var s = start; s < end && s < spineOrder.length; s++) {
        final content = htmlContent[spineOrder[s]]?.Content;
        if (content != null && content.trim().isNotEmpty) {
          paragraphs.addAll(_extractParagraphs(content));
        }
      }

      if (paragraphs.isNotEmpty) {
        chapters.add(ParsedChapter(
          title: usable[i].title ?? 'Chapter ${chapters.length + 1}',
          paragraphs: paragraphs,
        ));
      }
    }
  }

  // Fallback: if spine-based reconstruction produced nothing usable (e.g.
  // missing spine/manifest data, or an unusual format), fall back to the
  // original TOC-only traversal so we still produce something rather than
  // an empty book.
  if (chapters.isEmpty) {
    void flatten(List<epubx.EpubChapter>? chapterList) {
      if (chapterList == null) return;
      for (final chapter in chapterList) {
        final content = chapter.HtmlContent;
        if (content != null && content.trim().isNotEmpty) {
          final paragraphs = _extractParagraphs(content);
          if (paragraphs.isNotEmpty) {
            chapters.add(ParsedChapter(
              title: (chapter.Title?.trim().isNotEmpty ?? false)
                  ? chapter.Title!.trim()
                  : 'Chapter ${chapters.length + 1}',
              paragraphs: paragraphs,
            ));
          }
        }
        flatten(chapter.SubChapters);
      }
    }

    flatten(epubBook.Chapters);
  }

  return ParsedBook(
    title: epubBook.Title?.trim().isNotEmpty == true
        ? epubBook.Title!.trim()
        : 'Untitled',
    author: epubBook.Author?.trim(),
    chapters: chapters,
  );
}

/// Walks the DOM of a chapter's XHTML and extracts visible text as a list
/// of paragraph strings, skipping empty/whitespace-only nodes and stripping
/// embedded tags (e.g. <em>, <span>) down to their plain text.
List<String> _extractParagraphs(String htmlContent) {
  final document = html_parser.parse(htmlContent);

  // Remove elements that never contain narrative text.
  document.querySelectorAll('script, style, head').forEach((e) => e.remove());

  final paragraphs = <String>[];

  // Most EPUB body text lives in <p> tags, but some sloppy exports use
  // <div> per paragraph instead, or bare text directly in <body>.
  final blockSelectors = ['p', 'div', 'li', 'blockquote'];
  final seen = <dom.Element>{};

  for (final selector in blockSelectors) {
    for (final el in document.querySelectorAll(selector)) {
      if (seen.contains(el)) continue;
      // Skip if this element's text is fully covered by a nested block
      // we've already captured (avoids duplicating a <p> nested in a <div>).
      final hasBlockChild = el.children.any(
        (c) => blockSelectors.contains(c.localName),
      );
      if (hasBlockChild) continue;

      final text = _cleanText(el.text);
      if (text.isNotEmpty) {
        paragraphs.add(text);
        seen.add(el);
      }
    }
  }

  // Fallback: if no block elements yielded text (some EPUBs are just a
  // wall of text with <br> tags), grab the body's raw text as one block.
  if (paragraphs.isEmpty) {
    final bodyText = _cleanText(document.body?.text ?? '');
    if (bodyText.isNotEmpty) paragraphs.add(bodyText);
  }

  return paragraphs;
}

/// Collapses whitespace/newlines introduced by HTML formatting into single
/// spaces, and trims. Does NOT alter punctuation — sentence splitting for
/// TTS happens later, on this cleaned text.
String _cleanText(String raw) {
  return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
}