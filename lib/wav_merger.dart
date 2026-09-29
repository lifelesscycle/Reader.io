import 'dart:io';
import 'dart:typed_data';

/// Minimal parsed representation of a canonical 44-byte-header PCM WAV file.
class _WavData {
  final int numChannels;
  final int sampleRate;
  final int bitsPerSample;
  final Uint8List pcmData;

  _WavData({
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.pcmData,
  });
}

/// Reads and merges per-sentence WAV files into one continuous chapter WAV.
///
/// Assumes all input files share the same format (they will, since they all
/// come from the same Piper voice/model) — this is verified and will throw
/// if a mismatch is found, rather than silently producing corrupt audio.
class WavMerger {
  /// Silence between sentences within the same paragraph — a short,
  /// natural breath-length pause.
  static const double interSentenceSilenceSeconds = 0.28;

  /// Silence at a paragraph break — noticeably longer, matching the pause
  /// a person naturally takes between paragraphs when reading aloud.
  static const double interParagraphSilenceSeconds = 0.65;

  /// A small silence prepended to the very start of the merged file.
  /// Android's audio pipeline (ExoPlayer/ AudioTrack cold start) can clip
  /// the first few dozen milliseconds of audio on first playback — this
  /// leading pad absorbs that clipping instead of losing real speech.
  static const double leadingSilenceSeconds = 0.15;

  /// Merges the WAV files at [sentencePaths] in order into a single WAV
  /// file written to [outputPath]. [paragraphBreakAfter] should have
  /// length `sentencePaths.length - 1`; a `true` at index i means a
  /// paragraph boundary falls between sentence i and sentence i+1, so the
  /// longer pause is used there instead of the short one. If omitted, all
  /// gaps use the shorter inter-sentence pause.
  ///
  /// Deletes none of the inputs — caller is responsible for cleanup of
  /// temp per-sentence files. Returns the duration of the merged audio.
  static Future<Duration> merge(
    List<String> sentencePaths,
    String outputPath, {
    List<bool>? paragraphBreakAfter,
  }) async {
    if (sentencePaths.isEmpty) {
      throw ArgumentError('Cannot merge an empty list of WAV files');
    }
    if (paragraphBreakAfter != null &&
        paragraphBreakAfter.length != sentencePaths.length - 1) {
      throw ArgumentError(
        'paragraphBreakAfter must have length sentencePaths.length - 1',
      );
    }

    final parsed = <_WavData>[];
    for (final path in sentencePaths) {
      final bytes = await File(path).readAsBytes();
      parsed.add(_parseWav(bytes, path));
    }

    final first = parsed.first;
    for (final w in parsed.skip(1)) {
      if (w.numChannels != first.numChannels ||
          w.sampleRate != first.sampleRate ||
          w.bitsPerSample != first.bitsPerSample) {
        throw StateError(
          'WAV format mismatch across sentence files — expected '
          '${first.sampleRate}Hz/${first.bitsPerSample}bit/'
          '${first.numChannels}ch, found ${w.sampleRate}Hz/'
          '${w.bitsPerSample}bit/${w.numChannels}ch',
        );
      }
    }

    Uint8List silenceOf(double seconds) => Uint8List(
          _silenceByteCount(
            sampleRate: first.sampleRate,
            numChannels: first.numChannels,
            bitsPerSample: first.bitsPerSample,
            seconds: seconds,
          ),
        );

    final leadingSilence = silenceOf(leadingSilenceSeconds);
    final shortGap = silenceOf(interSentenceSilenceSeconds);
    final longGap = silenceOf(interParagraphSilenceSeconds);

    final builder = BytesBuilder();
    builder.add(leadingSilence);
    for (var i = 0; i < parsed.length; i++) {
      builder.add(parsed[i].pcmData);
      if (i != parsed.length - 1) {
        final isParagraphBreak = paragraphBreakAfter?[i] ?? false;
        builder.add(isParagraphBreak ? longGap : shortGap);
      }
    }
    final mergedPcm = builder.toBytes();

    final header = _buildWavHeader(
      dataLength: mergedPcm.length,
      numChannels: first.numChannels,
      sampleRate: first.sampleRate,
      bitsPerSample: first.bitsPerSample,
    );

    final outFile = File(outputPath);
    final sink = outFile.openWrite();
    sink.add(header);
    sink.add(mergedPcm);
    await sink.close();

    final bytesPerSecond =
        first.sampleRate * first.numChannels * (first.bitsPerSample ~/ 8);
    return Duration(
      microseconds: mergedPcm.length * Duration.microsecondsPerSecond ~/ bytesPerSecond,
    );
  }

  static int _silenceByteCount({
    required int sampleRate,
    required int numChannels,
    required int bitsPerSample,
    required double seconds,
  }) {
    final bytesPerSample = bitsPerSample ~/ 8;
    final frames = (sampleRate * seconds).round();
    return frames * numChannels * bytesPerSample;
  }

  static _WavData _parseWav(Uint8List bytes, String sourcePath) {
    final data = ByteData.sublistView(bytes);

    String fourCC(int offset) => String.fromCharCodes(
          bytes.sublist(offset, offset + 4),
        );

    if (fourCC(0) != 'RIFF' || fourCC(8) != 'WAVE') {
      throw FormatException('Not a valid WAV file: $sourcePath');
    }

    // Walk chunks rather than assuming a fixed 44-byte header, so this
    // tolerates minor encoder differences (e.g. an extra LIST chunk).
    var offset = 12;
    int? numChannels, sampleRate, bitsPerSample;
    Uint8List? pcmData;

    while (offset + 8 <= bytes.length) {
      final chunkId = fourCC(offset);
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final chunkStart = offset + 8;

      if (chunkId == 'fmt ') {
        numChannels = data.getUint16(chunkStart + 2, Endian.little);
        sampleRate = data.getUint32(chunkStart + 4, Endian.little);
        bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
      } else if (chunkId == 'data') {
        pcmData = bytes.sublist(chunkStart, chunkStart + chunkSize);
      }

      // Chunks are word-aligned; pad by 1 byte if chunkSize is odd.
      offset = chunkStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (numChannels == null || sampleRate == null || bitsPerSample == null) {
      throw FormatException('Missing fmt chunk in WAV: $sourcePath');
    }
    if (pcmData == null) {
      throw FormatException('Missing data chunk in WAV: $sourcePath');
    }

    return _WavData(
      numChannels: numChannels,
      sampleRate: sampleRate,
      bitsPerSample: bitsPerSample,
      pcmData: pcmData,
    );
  }

  static Uint8List _buildWavHeader({
    required int dataLength,
    required int numChannels,
    required int sampleRate,
    required int bitsPerSample,
  }) {
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final riffChunkSize = 36 + dataLength;

    final header = ByteData(44);
    void putFourCC(int offset, String cc) {
      for (var i = 0; i < 4; i++) {
        header.setUint8(offset + i, cc.codeUnitAt(i));
      }
    }

    putFourCC(0, 'RIFF');
    header.setUint32(4, riffChunkSize, Endian.little);
    putFourCC(8, 'WAVE');
    putFourCC(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // fmt chunk size (PCM)
    header.setUint16(20, 1, Endian.little); // audio format = 1 (PCM)
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    putFourCC(36, 'data');
    header.setUint32(40, dataLength, Endian.little);

    return header.buffer.asUint8List();
  }
}