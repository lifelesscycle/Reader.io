import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'epub_parser.dart';
import 'sentence_splitter.dart';
import 'wav_merger.dart';
import 'piper_tts_engine.dart';

/// Reports progress during chapter synthesis: [completed] sentences done
/// out of [total].
typedef SynthesisProgressCallback = void Function(int completed, int total);

/// Synthesizes a full chapter to a single gapless audio file, using
/// sentence-level synthesis under the hood (Piper/sherpa-onnx is not a
/// streaming synthesizer — it only handles one call per block of text).
///
/// Caches by (bookId, chapterIndex): once a chapter has been synthesized,
/// reopening it returns the cached file instantly instead of re-synthesizing.
class ChapterSynthesizer {
  final PiperTtsEngine engine;

  ChapterSynthesizer(this.engine);

  /// Returns the path to the finished chapter WAV file, synthesizing it
  /// first if not already cached.
  Future<String> synthesizeChapter({
    required String bookId,
    required int chapterIndex,
    required ParsedChapter chapter,
    SynthesisProgressCallback? onProgress,
  }) async {
    final cachedPath = await _cachedChapterPath(bookId, chapterIndex);
    if (await File(cachedPath).exists()) {
      return cachedPath;
    }

    // Split per paragraph (not the whole flattened chapter) so we can tell
    // the merger exactly where paragraph boundaries fall — that's what
    // lets it use a longer pause there than between ordinary sentences.
    final sentences = <String>[];
    final isLastInParagraph = <bool>[];

    for (final paragraph in chapter.paragraphs) {
      final paragraphSentences = SentenceSplitter.split(paragraph);
      for (var s = 0; s < paragraphSentences.length; s++) {
        sentences.add(paragraphSentences[s]);
        isLastInParagraph.add(s == paragraphSentences.length - 1);
      }
    }

    if (sentences.isEmpty) {
      throw StateError('Chapter has no synthesizable text');
    }

    // paragraphBreakAfter[i] = true means a paragraph boundary falls right
    // after sentence i — one entry per gap, so length is sentences.length - 1.
    final paragraphBreakAfter = isLastInParagraph.sublist(
      0,
      isLastInParagraph.length - 1,
    );

    final tempDir = await _tempSentenceDir(bookId, chapterIndex);
    final sentenceFiles = <String>[];

    for (var i = 0; i < sentences.length; i++) {
      final sentencePath = '${tempDir.path}/sentence_$i.wav';
      await engine.synthesizeToFile(sentences[i], sentencePath);
      sentenceFiles.add(sentencePath);
      onProgress?.call(i + 1, sentences.length);

      // Each native synthesize call blocks the isolate for its duration.
      // Back-to-back over dozens of sentences, that's long enough to
      // freeze input handling and trigger Android's ANR watchdog. This
      // explicit yield hands control back to the event loop (and Flutter's
      // frame/input pump) between sentences, keeping the app responsive.
      await Future.delayed(Duration.zero);
    }

    await WavMerger.merge(sentenceFiles, cachedPath, paragraphBreakAfter: paragraphBreakAfter);

    // Clean up per-sentence temp files now that the merged file exists —
    // keep only the final chapter WAV in the persistent cache.
    for (final f in sentenceFiles) {
      final file = File(f);
      if (await file.exists()) await file.delete();
    }
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }

    return cachedPath;
  }

  /// Deletes a cached chapter's synthesized audio, forcing re-synthesis
  /// next time it's requested. Useful during development when iterating
  /// on synthesis quality/parameters.
  Future<void> invalidateCache(String bookId, int chapterIndex) async {
    final path = await _cachedChapterPath(bookId, chapterIndex);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<String> _cachedChapterPath(String bookId, int chapterIndex) async {
    final dir = await _chapterCacheDir();
    final safeBookId = bookId.replaceAll(RegExp(r'[^\w\-]'), '_');
    return '${dir.path}/${safeBookId}_ch$chapterIndex.wav';
  }

  Future<Directory> _chapterCacheDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/chapter_audio_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _tempSentenceDir(String bookId, int chapterIndex) async {
    final tempRoot = await getTemporaryDirectory();
    final safeBookId = bookId.replaceAll(RegExp(r'[^\w\-]'), '_');
    final dir = Directory(
      '${tempRoot.path}/synth_temp/${safeBookId}_ch$chapterIndex',
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    return dir;
  }
}