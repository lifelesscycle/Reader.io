import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';
import 'package:archive/archive.dart';

/// Copies the bundled Piper voice model out of Flutter's asset bundle into
/// a real directory on disk, since sherpa-onnx's native code needs actual
/// file paths (not asset bundle references) to load the model.
///
/// espeak-ng-data has a deeply nested directory structure (e.g.
/// lang/gmw/en, lang/gmw/en-US) that Flutter's asset system cannot bundle
/// via non-recursive directory declarations. To work around this, that
/// folder is pre-zipped into a single espeak-ng-data.zip asset and
/// extracted here with package:archive, which preserves the full nested
/// structure exactly as espeak-ng needs it.
class PiperModelAssets {
  static const _assetDir = 'assets/piper/en_US-lessac-medium';
  static const _files = [
    'en_US-lessac-medium.onnx',
    'en_US-lessac-medium.onnx.json',
    'tokens.txt',
  ];

  /// Returns the on-disk directory containing the extracted model files.
  static Future<String> ensureExtracted() async {
    final appDir = await getApplicationSupportDirectory();
    final targetDir = Directory('${appDir.path}/piper/en_US-lessac-medium');

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    for (final fileName in _files) {
      final targetFile = File('${targetDir.path}/$fileName');
      if (!await targetFile.exists()) {
        final data = await rootBundle.load('$_assetDir/$fileName');
        await targetFile.writeAsBytes(data.buffer.asUint8List());
      }
    }

    final espeakTargetDir = Directory('${targetDir.path}/espeak-ng-data');
    // Marker file confirms extraction fully completed last time — checking
    // the directory's mere existence isn't reliable if a previous run was
    // interrupted partway through writing hundreds of zip entries.
    final marker = File('${espeakTargetDir.path}/.extracted');
    if (!await marker.exists()) {
      if (await espeakTargetDir.exists()) {
        await espeakTargetDir.delete(recursive: true);
      }
      await espeakTargetDir.create(recursive: true);

      final zipData = await rootBundle.load('$_assetDir/espeak-ng-data.zip');
      final archive = ZipDecoder().decodeBytes(zipData.buffer.asUint8List());

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

/// Wraps sherpa-onnx's OfflineTts for the Piper voice.
///
/// [initFromModelDir] is pure FFI + file access, so it can run inside a
/// background isolate (which has no access to Flutter assets or plugins).
/// [init] is the main-isolate convenience that extracts assets first.
class PiperTtsEngine {
  /// Tuned by ear on real chapters; the model's raw 1.0 read too fast.
  static const double defaultSpeed = 0.90;

  OfflineTts? _tts;

  Future<void> init() async {
    final modelDir = await PiperModelAssets.ensureExtracted();
    initFromModelDir(modelDir);
  }

  /// Loads the model from an already-extracted [modelDir]. Throws a clear
  /// error if any expected file is missing, rather than letting the native
  /// layer fail with its generic "check your config" message.
  void initFromModelDir(String modelDir, {int numThreads = 2}) {
    initBindings(); // sherpa_onnx native binding init (per-isolate)

    final model = '$modelDir/en_US-lessac-medium.onnx';
    final tokens = '$modelDir/tokens.txt';
    final dataDir = '$modelDir/espeak-ng-data';

    if (!File(model).existsSync()) {
      throw StateError('Missing model file: $model');
    }
    if (!File(tokens).existsSync()) {
      throw StateError('Missing tokens file: $tokens');
    }
    if (!Directory(dataDir).existsSync()) {
      throw StateError('Missing espeak-ng-data directory: $dataDir');
    }

    final vits = OfflineTtsVitsModelConfig(
      model: model,
      tokens: tokens,
      dataDir: dataDir,
    );
    final modelConfig = OfflineTtsModelConfig(
      vits: vits,
      numThreads: numThreads,
      debug: false,
    );
    _tts = OfflineTts(OfflineTtsConfig(model: modelConfig));
  }

  /// Synthesizes [text] and writes a WAV file to [outputPath].
  /// [speed] is Piper's speed multiplier — below 1.0 is slower, above 1.0
  /// is faster. Returns the sample rate used.
  Future<int> synthesizeToFile(
    String text,
    String outputPath, {
    double speed = defaultSpeed,
  }) async {
    final tts = _tts;
    if (tts == null) {
      throw StateError('PiperTtsEngine not initialized');
    }
    final audio = tts.generate(text: text, sid: 0, speed: speed);
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