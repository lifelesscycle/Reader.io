import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';
import 'package:archive/archive.dart';

/// Copies the bundled Kokoro model out of Flutter's asset bundle into a real
/// directory on disk, since sherpa-onnx's native code needs actual file
/// paths (not asset bundle references) to load the model.
///
/// Expected assets (from the `kokoro-en-v0_19` sherpa-onnx package):
///   assets/kokoro/kokoro-en-v0_19/model.onnx
///   assets/kokoro/kokoro-en-v0_19/voices.bin
///   assets/kokoro/kokoro-en-v0_19/tokens.txt
///   assets/kokoro/kokoro-en-v0_19/espeak-ng-data.zip   (zipped folder)
///
/// espeak-ng-data has a deeply nested directory structure that Flutter's
/// asset system cannot bundle via non-recursive directory declarations, so
/// it is pre-zipped and extracted here with package:archive.
class KokoroModelAssets {
  static const _assetDir = 'assets/kokoro/kokoro-en-v0_19';
  static const _files = [
    'model.onnx',
    'voices.bin',
    'tokens.txt',
  ];

  /// Returns the on-disk directory containing the extracted model files.
  static Future<String> ensureExtracted() async {
    final appDir = await getApplicationSupportDirectory();
    final targetDir = Directory('${appDir.path}/kokoro/kokoro-en-v0_19');

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    for (final fileName in _files) {
      final targetFile = File('${targetDir.path}/$fileName');
      if (!await targetFile.exists()) {
        final data = await rootBundle.load('$_assetDir/$fileName');
        // Write to a temp name and rename, so an interrupted copy of a
        // large file can never be mistaken for a complete one next launch.
        final tmp = File('${targetFile.path}.tmp');
        await tmp.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await tmp.rename(targetFile.path);
      }
    }

    final espeakTargetDir = Directory('${targetDir.path}/espeak-ng-data');
    // Marker file confirms extraction fully completed last time.
    final marker = File('${espeakTargetDir.path}/.extracted');
    if (!await marker.exists()) {
      if (await espeakTargetDir.exists()) {
        await espeakTargetDir.delete(recursive: true);
      }
      await espeakTargetDir.create(recursive: true);

      final zipData = await rootBundle.load('$_assetDir/espeak-ng-data.zip');
      final archive = ZipDecoder().decodeBytes(
        zipData.buffer.asUint8List(zipData.offsetInBytes, zipData.lengthInBytes),
      );

      for (final entry in archive) {
        final outPath = '${espeakTargetDir.path}/${entry.name}';
        if (entry.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(entry.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }

      await marker.writeAsString('done');
    }

    return targetDir.path;
  }
}

/// Wraps sherpa-onnx's OfflineTts for the Kokoro voice.
///
/// [initFromModelDir] is pure FFI + file access, so it can run inside a
/// background isolate (which has no access to Flutter assets or plugins).
/// [init] is the main-isolate convenience that extracts assets first.
class KokoroTtsEngine {
  /// Kokoro's native pace is 1.0. (The old 0.90 was tuned for Piper.)
  /// Re-tune by ear.
  static const double defaultSpeed = 1.0;

  /// Speaker id. kokoro-en-v0_19 has 11 speakers, ids 0-10. See the
  /// speaker table in the sherpa-onnx Kokoro docs for which id is which.
  static const int defaultSid = 0;

  OfflineTts? _tts;

  Future<void> init() async {
    final modelDir = await KokoroModelAssets.ensureExtracted();
    initFromModelDir(modelDir);
  }

  /// Loads the model from an already-extracted [modelDir]. Throws a clear
  /// error if any expected file is missing, rather than letting the native
  /// layer fail with its generic "check your config" message.
  void initFromModelDir(String modelDir, {int numThreads = 6}) {
    initBindings(); // sherpa_onnx native binding init (per-isolate)

    final model = '$modelDir/model.onnx';
    final voices = '$modelDir/voices.bin';
    final tokens = '$modelDir/tokens.txt';
    final dataDir = '$modelDir/espeak-ng-data';

    if (!File(model).existsSync()) {
      throw StateError('Missing model file: $model');
    }
    if (!File(voices).existsSync()) {
      throw StateError('Missing voices file: $voices');
    }
    if (!File(tokens).existsSync()) {
      throw StateError('Missing tokens file: $tokens');
    }
    if (!Directory(dataDir).existsSync()) {
      throw StateError('Missing espeak-ng-data directory: $dataDir');
    }

    final kokoro = OfflineTtsKokoroModelConfig(
      model: model,
      voices: voices,
      tokens: tokens,
      dataDir: dataDir,
    );
    final modelConfig = OfflineTtsModelConfig(
      kokoro: kokoro,
      numThreads: numThreads,
      debug: false,
    );
    _tts = OfflineTts(OfflineTtsConfig(model: modelConfig));
  }

  /// Synthesizes [text] and writes a WAV file to [outputPath].
  /// [speed] is a pace multiplier — below 1.0 is slower, above 1.0 is
  /// faster. [sid] selects the voice. Returns the sample rate used.
  Future<int> synthesizeToFile(
    String text,
    String outputPath, {
    int sid = defaultSid,
    double speed = defaultSpeed,
  }) async {
    final tts = _tts;
    if (tts == null) {
      throw StateError('KokoroTtsEngine not initialized');
    }
    final audio = tts.generate(text: text, sid: sid, speed: speed);
    final ok = writeWave(
      filename: outputPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );
    if (!ok) {
      throw StateError('writeWave failed to write $outputPath');
    }
    return audio.sampleRate;
  }

  void dispose() {
    _tts?.free();
    _tts = null;
  }
}
