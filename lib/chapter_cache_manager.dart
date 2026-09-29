import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'epub_parser.dart';
import 'sentence_splitter.dart';
import 'synthesis_worker.dart';

/// Thrown from [ChapterCacheManager.getChapter] when a request was
/// superseded (another chapter was requested, the book changed, or the
/// chapter fell out of the cache window). Not a real failure — callers
/// should just stop quietly.
class SynthesisCancelled implements Exception {
  @override
  String toString() => 'Synthesis cancelled';
}

typedef ChapterProgress = void Function(int done, int total);

class _ChapterTask {
  final int index;
  final Completer<String> completer = Completer<String>();
  final List<ChapterProgress> listeners = [];
  bool foreground;

  _ChapterTask(this.index, {required this.foreground}) {
    // Background prefetch tasks usually have no listener; without this an
    // error on their future would surface as an unhandled async error.
    completer.future.ignore();
  }
}

/// Decides which chapter audio exists on disk and keeps it bounded.
///
/// Cache policy: keep a window of 2n+1 chapters around the current one
/// (n behind, n ahead) for the open book and delete everything else,
/// including every other book's audio. Disk use is therefore capped at
/// roughly 2n+1 chapters no matter how large the library gets.
///
/// Scheduling: the worker runs one job at a time. A foreground request
/// (the chapter the user is waiting on) always outranks background
/// prefetch: a running prefetch is cancelled to make room, unless it is
/// already producing the very chapter that was requested.
class ChapterCacheManager {
  ChapterCacheManager({
    required this.worker,
    required this.cacheDir,
    required this.tempRoot,
    this.windowRadius = 1,
    this.prefetchBehind = false,
  });

  final SynthesisWorker worker;
  final Directory cacheDir;
  final Directory tempRoot;

  /// n in the 2n+1 window.
  final int windowRadius;

  /// Whether to also synthesize chapters *behind* the current one. Off by
  /// default: chapters already listened to are kept if they exist, but
  /// synthesizing them ahead of time would burn battery on audio you
  /// rarely go back to.
  final bool prefetchBehind;

  /// Human-readable status of background work, for the UI.
  final ValueNotifier<String> backgroundStatus = ValueNotifier<String>('');

  String? _bookId;
  ParsedBook? _book;

  final Map<int, _ChapterTask> _tasks = {};
  final List<int> _queue = [];
  int? _running;
  SynthesisHandle? _runningHandle;

  /// Bumped whenever queued/running work is abandoned, so late results from
  /// the old generation are ignored.
  int _generation = 0;
  bool _disposed = false;

  static final _cacheName = RegExp(r'^(.+)_ch(\d+)\.wav$');

  String _pathFor(int index) => '${cacheDir.path}/${_bookId}_ch$index.wav';

  /// Switches to a new book: abandons any work for the previous one and
  /// deletes audio belonging to other books.
  Future<void> openBook(String bookId, ParsedBook book) async {
    await _cancelEverything();
    _bookId = bookId;
    _book = book;
    backgroundStatus.value = '';
    await _deleteStaleParts();
    await _purge((b, _) => b == bookId);
  }

  /// Returns the audio file for chapter [index], synthesizing it first if
  /// needed. This is the foreground path: it takes priority over any
  /// background prefetch. [onProgress] reports sentences completed.
  Future<String> getChapter(int index, {ChapterProgress? onProgress}) {
    final path = _pathFor(index);
    if (File(path).existsSync()) return Future.value(path);

    var task = _tasks[index];
    if (task == null) {
      task = _ChapterTask(index, foreground: true);
      _tasks[index] = task;
      _queue.insert(0, index);
    } else {
      task.foreground = true;
      if (_running != index) {
        _queue.remove(index);
        _queue.insert(0, index);
      }
    }
    if (onProgress != null) task.listeners.add(onProgress);

    // The user is waiting on this chapter: stop background work for others.
    if (_running != null && _running != index) {
      final handle = _runningHandle;
      if (handle != null) worker.cancel(handle);
    }

    _pump();
    return task.completer.future;
  }

  /// Call once the chapter at [center] is loaded and playing. Evicts audio
  /// outside the window and queues background synthesis of the chapters
  /// ahead.
  void updateWindow(int center) {
    final book = _book;
    final bookId = _bookId;
    if (book == null || bookId == null || book.chapters.isEmpty) return;

    final total = book.chapters.length;
    final lo = math.max(0, center - windowRadius);
    final hi = math.min(total - 1, center + windowRadius);
    final desired = <int>{for (var i = lo; i <= hi; i++) i};

    // Drop queued work that fell outside the window.
    for (final i in _queue.toList()) {
      if (!desired.contains(i)) {
        _queue.remove(i);
        _tasks.remove(i)?.completer.completeError(SynthesisCancelled());
      }
    }
    // Stop the running job if it fell outside the window.
    final running = _running;
    if (running != null && !desired.contains(running)) {
      final handle = _runningHandle;
      if (handle != null) worker.cancel(handle);
    }

    // Evict cached audio outside the window.
    unawaited(_purge((b, i) => b == bookId && desired.contains(i)));

    // Queue prefetch, nearest chapter ahead first.
    for (var i = center + 1; i <= hi; i++) {
      _enqueuePrefetch(i);
    }
    if (prefetchBehind) {
      for (var i = center - 1; i >= lo; i--) {
        _enqueuePrefetch(i);
      }
    }
    _pump();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _cancelEverything();
    backgroundStatus.dispose();
  }

  // ---- internals ----------------------------------------------------------

  void _enqueuePrefetch(int index) {
    if (File(_pathFor(index)).existsSync()) return;
    if (_tasks.containsKey(index)) return; // already queued or running
    _tasks[index] = _ChapterTask(index, foreground: false);
    _queue.add(index);
  }

  void _pump() {
    if (_disposed || _running != null || _queue.isEmpty) return;

    final index = _queue.removeAt(0);
    final task = _tasks[index];
    final book = _book;
    final bookId = _bookId;
    if (task == null || book == null || bookId == null) {
      _pump();
      return;
    }

    // Split per paragraph so paragraph ends can get a longer pause.
    final sentences = <String>[];
    final isLastInParagraph = <bool>[];
    for (final paragraph in book.chapters[index].paragraphs) {
      final parts = SentenceSplitter.split(paragraph);
      for (var s = 0; s < parts.length; s++) {
        sentences.add(parts[s]);
        isLastInParagraph.add(s == parts.length - 1);
      }
    }
    if (sentences.isEmpty) {
      _tasks.remove(index);
      task.completer.completeError(
        StateError('Chapter ${index + 1} has no readable text'),
      );
      _pump();
      return;
    }

    final generation = _generation;
    final outputPath = _pathFor(index);
    _running = index;

    final handle = worker.run(
      sentences: sentences,
      paragraphBreakAfter: isLastInParagraph.sublist(0, sentences.length - 1),
      tempDir: '${tempRoot.path}/${bookId}_ch$index',
      outputPath: outputPath,
      onProgress: (done, total) {
        if (generation != _generation || _disposed) return;
        for (final listener in task.listeners) {
          listener(done, total);
        }
        if (!task.foreground) {
          backgroundStatus.value =
              'Preparing chapter ${index + 1} in the background… $done/$total';
        }
      },
    );
    _runningHandle = handle;

    handle.result.then((outcome) {
      if (generation != _generation || _disposed) return;
      _running = null;
      _runningHandle = null;
      _tasks.remove(index);

      switch (outcome.status) {
        case SynthesisStatus.done:
          task.completer.complete(outputPath);
          backgroundStatus.value =
              'Chapter ${index + 1} ready — ${_human(outcome.elapsed)} of work '
              'for ${_human(outcome.audioDuration)} of audio';
        case SynthesisStatus.cancelled:
          task.completer.completeError(SynthesisCancelled());
        case SynthesisStatus.failed:
          task.completer.completeError(
            StateError(outcome.error ?? 'Synthesis failed'),
          );
          backgroundStatus.value =
              'Chapter ${index + 1} failed: ${outcome.error ?? 'unknown error'}';
      }
      _pump();
    });
  }

  Future<void> _cancelEverything() async {
    _generation++;
    final handle = _runningHandle;

    final tasks = _tasks.values.toList();
    _tasks.clear();
    _queue.clear();
    for (final task in tasks) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(SynthesisCancelled());
      }
    }

    if (handle != null) {
      worker.cancel(handle);
      try {
        await handle.result;
      } catch (_) {}
    }
    _running = null;
    _runningHandle = null;
  }

  Future<void> _purge(bool Function(String bookId, int chapter) keep) async {
    try {
      if (!await cacheDir.exists()) return;
      final entries = await cacheDir.list().toList();
      for (final entry in entries) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final match = _cacheName.firstMatch(name);
        if (match == null) continue; // .part files and unknown files
        if (!keep(match.group(1)!, int.parse(match.group(2)!))) {
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Removes leftovers from jobs that were interrupted mid-way.
  Future<void> _deleteStaleParts() async {
    try {
      if (await cacheDir.exists()) {
        await for (final entry in cacheDir.list()) {
          if (entry is File && entry.path.endsWith('.part')) {
            try {
              await entry.delete();
            } catch (_) {}
          }
        }
      }
      if (await tempRoot.exists()) {
        await for (final entry in tempRoot.list()) {
          try {
            await entry.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static String _human(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }
}