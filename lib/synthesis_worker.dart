import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'kokoro_tts_engine.dart';
import 'wav_merger.dart';

enum SynthesisStatus { done, cancelled, failed }

/// Result of one chapter synthesis job.
class SynthesisOutcome {
  final SynthesisStatus status;

  /// Length of the finished audio (zero unless [status] is done).
  final Duration audioDuration;

  /// Wall-clock time the job took inside the worker.
  final Duration elapsed;
  final String? error;

  const SynthesisOutcome(
    this.status, {
    this.audioDuration = Duration.zero,
    this.elapsed = Duration.zero,
    this.error,
  });
}

/// Handle to a submitted job: lets the caller await the result or cancel.
class SynthesisHandle {
  final int id;
  final Future<SynthesisOutcome> result;
  SynthesisHandle._(this.id, this.result);
}

typedef SentenceProgress = void Function(int done, int total);

class _PendingJob {
  final Completer<SynthesisOutcome> completer = Completer<SynthesisOutcome>();
  final SentenceProgress? onProgress;
  _PendingJob(this.onProgress);
}

/// Runs chapter synthesis in a dedicated isolate.
///
/// Kokoro synthesis is a blocking native call. On the UI isolate it freezes
/// the app (and long enough, triggers Android's ANR kill), so all of it
/// lives here instead. The worker owns the app's only TTS engine.
///
/// Jobs run one at a time, in the order sent. Only plain data (strings,
/// lists, numbers) crosses the isolate boundary; the worker cannot use
/// Flutter assets or plugins, so the caller extracts the model files first
/// and resolves every directory path before submitting.
class SynthesisWorker {
  Isolate? _isolate;
  ReceivePort? _events;
  ReceivePort? _errors;
  SendPort? _commands;
  final Map<int, _PendingJob> _pending = {};
  int _nextId = 1;

  bool get isRunning => _commands != null;

  /// Spawns the worker and loads the model inside it. Completes when the
  /// engine is ready; throws if the model fails to load.
  Future<void> start(String modelDir) async {
    if (_isolate != null) return;

    final events = ReceivePort();
    final errors = ReceivePort();
    final ready = Completer<void>();

    events.listen((message) {
      if (message is _CommandPort) {
        _commands = message.port;
      } else if (message is _Ready) {
        if (!ready.isCompleted) ready.complete();
      } else if (message is _InitFailed) {
        if (!ready.isCompleted) ready.completeError(StateError(message.error));
      } else if (message is _ProgressEvent) {
        _pending[message.id]?.onProgress?.call(message.done, message.total);
      } else if (message is _FinishedEvent) {
        _pending.remove(message.id)?.completer.complete(
              SynthesisOutcome(
                message.status,
                audioDuration: Duration(milliseconds: message.audioMs),
                elapsed: Duration(milliseconds: message.elapsedMs),
                error: message.error,
              ),
            );
      }
    });

    errors.listen((message) {
      final text = (message is List && message.isNotEmpty)
          ? message.first.toString()
          : '$message';
      if (!ready.isCompleted) ready.completeError(StateError(text));
      _failAll('Synthesis worker crashed: $text');
    });

    _events = events;
    _errors = errors;

    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        _WorkerInit(events.sendPort, modelDir),
        onError: errors.sendPort,
      );
      await ready.future;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  /// Queues a chapter synthesis job. Progress is reported per sentence.
  SynthesisHandle run({
    required List<String> sentences,
    required List<bool> paragraphBreakAfter,
    required String tempDir,
    required String outputPath,
    double speed = KokoroTtsEngine.defaultSpeed,
    int sid = KokoroTtsEngine.defaultSid,
    SentenceProgress? onProgress,
  }) {
    final commands = _commands;
    if (commands == null) {
      throw StateError('SynthesisWorker is not running');
    }
    final id = _nextId++;
    final job = _PendingJob(onProgress);
    _pending[id] = job;
    commands.send(_JobCommand(
      id: id,
      sentences: sentences,
      paragraphBreakAfter: paragraphBreakAfter,
      tempDir: tempDir,
      outputPath: outputPath,
      speed: speed,
      sid: sid,
    ));
    return SynthesisHandle._(id, job.completer.future);
  }

  /// Asks the worker to abandon a job. Takes effect at the next sentence
  /// boundary; the job's future then completes with status cancelled.
  void cancel(SynthesisHandle handle) {
    _commands?.send(_CancelCommand(handle.id));
  }

  Future<void> stop() async {
    _commands?.send(const _ShutdownCommand());
    _commands = null;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _events?.close();
    _errors?.close();
    _events = null;
    _errors = null;
    _failAll('Synthesis worker stopped');
  }

  void _failAll(String error) {
    final jobs = _pending.values.toList();
    _pending.clear();
    for (final job in jobs) {
      if (!job.completer.isCompleted) {
        job.completer.complete(
          SynthesisOutcome(SynthesisStatus.failed, error: error),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Messages between the main isolate and the worker (plain sendable data).
// ---------------------------------------------------------------------------

class _WorkerInit {
  final SendPort events;
  final String modelDir;
  const _WorkerInit(this.events, this.modelDir);
}

class _JobCommand {
  final int id;
  final List<String> sentences;
  final List<bool> paragraphBreakAfter;
  final String tempDir;
  final String outputPath;
  final double speed;
  final int sid;
  const _JobCommand({
    required this.id,
    required this.sentences,
    required this.paragraphBreakAfter,
    required this.tempDir,
    required this.outputPath,
    required this.speed,
    required this.sid,
  });
}

class _CancelCommand {
  final int id;
  const _CancelCommand(this.id);
}

class _ShutdownCommand {
  const _ShutdownCommand();
}

class _CommandPort {
  final SendPort port;
  const _CommandPort(this.port);
}

class _Ready {
  const _Ready();
}

class _InitFailed {
  final String error;
  const _InitFailed(this.error);
}

class _ProgressEvent {
  final int id;
  final int done;
  final int total;
  const _ProgressEvent(this.id, this.done, this.total);
}

class _FinishedEvent {
  final int id;
  final SynthesisStatus status;
  final int audioMs;
  final int elapsedMs;
  final String? error;
  const _FinishedEvent(
    this.id,
    this.status,
    this.audioMs,
    this.elapsedMs,
    this.error,
  );
}

// ---------------------------------------------------------------------------
// Worker side.
// ---------------------------------------------------------------------------

Future<void> _workerMain(_WorkerInit init) async {
  final commands = ReceivePort();
  init.events.send(_CommandPort(commands.sendPort));

  final engine = KokoroTtsEngine();
  try {
    engine.initFromModelDir(init.modelDir);
  } catch (e) {
    init.events.send(_InitFailed('$e'));
    commands.close();
    return;
  }
  init.events.send(const _Ready());

  final cancelled = <int>{};

  // listen() rather than `await for`: an `await for` body pauses message
  // delivery while a job runs, which would make cancel commands arrive
  // only after the job had already finished.
  commands.listen((message) {
    if (message is _JobCommand) {
      unawaited(_runJob(message, engine, cancelled, init.events));
    } else if (message is _CancelCommand) {
      cancelled.add(message.id);
    } else if (message is _ShutdownCommand) {
      engine.dispose();
      commands.close();
    }
  });
}

Future<void> _runJob(
  _JobCommand job,
  KokoroTtsEngine engine,
  Set<int> cancelled,
  SendPort events,
) async {
  final clock = Stopwatch()..start();
  final tempDir = Directory(job.tempDir);

  void finish(SynthesisStatus status, {int audioMs = 0, String? error}) {
    cancelled.remove(job.id);
    events.send(_FinishedEvent(
      job.id,
      status,
      audioMs,
      clock.elapsedMilliseconds,
      error,
    ));
  }

  try {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);

    final files = <String>[];
    for (var i = 0; i < job.sentences.length; i++) {
      if (cancelled.contains(job.id)) {
        await _deleteQuietly(tempDir);
        finish(SynthesisStatus.cancelled);
        return;
      }
      final path = '${job.tempDir}/sentence_$i.wav';
      await engine.synthesizeToFile(
        job.sentences[i],
        path,
        sid: job.sid,
        speed: job.speed,
      );
      files.add(path);
      events.send(_ProgressEvent(job.id, i + 1, job.sentences.length));

      // Yield to this isolate's event loop so a cancel command can be
      // delivered between sentences.
      await Future<void>.delayed(Duration.zero);
    }

    if (cancelled.contains(job.id)) {
      await _deleteQuietly(tempDir);
      finish(SynthesisStatus.cancelled);
      return;
    }

    // Write to a .part file and rename when complete, so a chapter file
    // that exists under its final name is always whole — even if the app
    // is killed halfway through the merge.
    final partPath = '${job.outputPath}.part';
    final audio = await WavMerger.merge(
      files,
      partPath,
      paragraphBreakAfter: job.paragraphBreakAfter,
    );
    await File(partPath).rename(job.outputPath);

    await _deleteQuietly(tempDir);
    finish(SynthesisStatus.done, audioMs: audio.inMilliseconds);
  } catch (e) {
    await _deleteQuietly(tempDir);
    finish(SynthesisStatus.failed, error: '$e');
  }
}

Future<void> _deleteQuietly(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}