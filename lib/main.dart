import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:path_provider/path_provider.dart';
import 'book_identity.dart';
import 'chapter_cache_manager.dart';
import 'epub_parser.dart';
import 'kokoro_tts_engine.dart';
import 'reading_progress_store.dart';
import 'synthesis_worker.dart';

/// n in the cache window: keep n chapters behind and n ahead of the current
/// one (2n+1 chapters of audio on disk). Everything else is deleted.
const int kCacheWindowRadius = 1;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before any AudioPlayer is constructed. Registers the media
  // session + foreground service that keeps audio alive with the screen
  // off and provides the notification / lock-screen controls.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.webnovel_tts_reader.channel.audio',
    androidNotificationChannelName: 'Audiobook playback',
    androidNotificationOngoing: true,
  );
  await ReadingProgressStore.init();
  runApp(const PlayerApp());
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Webnovel TTS Reader',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const PlayerScreen(),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  final _worker = SynthesisWorker();
  ChapterCacheManager? _cache;
  final _player = AudioPlayer();

  ParsedBook? _book;
  String? _bookId;

  /// Chapter highlighted in the dropdown (may not be loaded yet).
  int? _selectedChapterIndex;

  /// Chapter whose audio is actually loaded in the player right now.
  /// Progress is always saved against this one, never the dropdown value.
  int? _loadedChapterIndex;

  /// Saved progress found when the book was opened; applied once, when the
  /// matching chapter is loaded, so reopening resumes where you left off.
  ReadingProgress? _pendingResume;

  bool _engineReady = false;
  bool _busy = false;
  String _status = 'Tap "Initialize" to start';
  int _progressDone = 0;
  int _progressTotal = 0;

  /// Non-null while the user is dragging the scrub bar.
  double? _dragValueMs;

  /// Incremented for every chapter load; a load that finds its token stale
  /// after an await has been superseded and must stop quietly.
  int _loadToken = 0;
  bool _advancing = false;

  Timer? _autosaveTimer;
  StreamSubscription<ProcessingState>? _processingSub;

  static const _skipSeconds = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Safety net for abrupt kills: while playing, persist position every
    // few seconds so at most a few seconds of progress can ever be lost.
    _autosaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_player.playing) _saveProgress();
    });
    _processingSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onChapterFinished();
    });
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _processingSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _saveProgress();
    _cache?.dispose();
    _worker.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Anything other than "resumed" means the app is leaving the
    // foreground and could be killed at any moment.
    if (state != AppLifecycleState.resumed) {
      _saveProgress();
    }
  }

  Future<void> _saveProgress() async {
    final id = _bookId;
    final chapter = _loadedChapterIndex;
    if (id == null || chapter == null) return;
    await ReadingProgressStore.save(
      bookId: id,
      chapterIndex: chapter,
      positionMs: _player.position.inMilliseconds,
    );
  }

  Future<void> _initEngine() async {
    setState(() {
      _busy = true;
      _status = 'Starting speech engine...';
    });
    try {
      // Asset extraction needs Flutter plugins, so it happens here; the
      // worker isolate then loads the model from plain file paths.
      final modelDir = await KokoroModelAssets.ensureExtracted();
      await _worker.start(modelDir);

      final support = await getApplicationSupportDirectory();
      final temp = await getTemporaryDirectory();
      final cacheDir = Directory('${support.path}/chapter_audio_cache');
      final tempRoot = Directory('${temp.path}/synth_temp');
      await cacheDir.create(recursive: true);
      await tempRoot.create(recursive: true);

      _cache = ChapterCacheManager(
        worker: _worker,
        cacheDir: cacheDir,
        tempRoot: tempRoot,
        windowRadius: kCacheWindowRadius,
      );

      setState(() {
        _engineReady = true;
        _status = 'Engine ready — pick an EPUB file';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Init failed: $e';
        _busy = false;
      });
    }
  }

  Future<void> _pickEpub() async {
    final cache = _cache;
    if (cache == null) return;
    setState(() {
      _busy = true;
      _status = 'Parsing EPUB...';
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['epub'],
      );
      if (file == null) {
        setState(() => _busy = false);
        return;
      }

      // Bank progress on whatever was playing, then drop any in-flight load.
      await _saveProgress();
      _loadToken++;
      await _player.stop();

      final bytes = await file.readAsBytes();
      final bookId = computeBookId(bytes);
      final book = await parseEpub(bytes);

      // Abandons the old book's work and deletes other books' audio.
      await cache.openBook(bookId, book);

      // Restore: if this book has saved progress, preselect that chapter
      // and remember the position to seek to once it's loaded.
      final saved = ReadingProgressStore.load(bookId);
      final canResume = saved != null && saved.chapterIndex < book.chapters.length;

      setState(() {
        _book = book;
        _bookId = bookId;
        _loadedChapterIndex = null;
        _selectedChapterIndex = canResume ? saved.chapterIndex : null;
        _pendingResume = canResume ? saved : null;
        _progressTotal = 0;
        _status = canResume
            ? 'Welcome back — you were on chapter ${saved.chapterIndex + 1} '
                'at ${_fmt(Duration(milliseconds: saved.positionMs))}. '
                'Tap "Play chapter" to resume.'
            : 'Parsed "${book.title}" — ${book.chapters.length} chapters. Pick one.';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Parse failed: $e';
        _busy = false;
      });
    }
  }

  /// Prepares chapter [index] (synthesizing it if it isn't cached), loads
  /// it into the player and starts playback. Once playback has started the
  /// cache manager begins preparing the following chapters in the
  /// background.
  ///
  /// [fromUser] is false for automatic chapter changes: in that case the
  /// previous chapter is left playing/finished rather than paused, which
  /// keeps the background media service alive while the next chapter is
  /// prepared.
  Future<void> _loadChapter(int index, {bool fromUser = true}) async {
    final cache = _cache;
    final book = _book;
    final bookId = _bookId;
    if (cache == null || book == null || bookId == null) return;

    final token = ++_loadToken;
    final chapter = book.chapters[index];

    if (fromUser) {
      await _saveProgress();
      await _player.pause();
    }

    setState(() {
      _busy = true;
      _progressDone = 0;
      _progressTotal = 0;
      _status = 'Preparing "${chapter.title}"...';
    });

    final String path;
    try {
      path = await cache.getChapter(
        index,
        onProgress: (done, total) {
          if (token != _loadToken || !mounted) return;
          setState(() {
            _progressDone = done;
            _progressTotal = total;
            _status = 'Synthesizing "${chapter.title}" — sentence $done / $total';
          });
        },
      );
    } on SynthesisCancelled {
      return; // superseded by a newer request
    } catch (e) {
      if (token == _loadToken && mounted) {
        setState(() {
          _status = 'Could not prepare chapter: $e';
          _busy = false;
        });
      }
      return;
    }
    if (token != _loadToken || !mounted) return;

    // The MediaItem tag is mandatory with just_audio_background — it
    // supplies the title/author shown in the notification and lock screen.
    final loadedDuration = await _player.setAudioSource(
      AudioSource.uri(
        Uri.file(path),
        tag: MediaItem(
          id: '$bookId-$index',
          album: book.title,
          title: chapter.title,
          artist: book.author,
        ),
      ),
    );
    if (token != _loadToken || !mounted) return;

    // Apply saved position only if it belongs to this exact chapter.
    var startAt = Duration.zero;
    final resume = _pendingResume;
    if (resume != null && resume.chapterIndex == index) {
      final total = loadedDuration ?? _player.duration ?? Duration.zero;
      var target = Duration(milliseconds: resume.positionMs);
      if (total > Duration.zero && target >= total) target = Duration.zero;
      startAt = target;
      await _player.seek(startAt);
    }
    _pendingResume = null;

    setState(() {
      _loadedChapterIndex = index;
      _selectedChapterIndex = index;
      _progressTotal = 0;
      _busy = false;
      _status = startAt > Duration.zero
          ? 'Resumed "${chapter.title}" at ${_fmt(startAt)}'
          : 'Playing "${chapter.title}"';
    });
    await _saveProgress();

    // Not awaited: play() only completes when playback pauses or ends.
    unawaited(_player.play());

    // Playback has started — now let the worker get on with the chapters
    // ahead, and trim the cache down to the window.
    cache.updateWindow(index);
  }

  Future<void> _onChapterFinished() async {
    final book = _book;
    final bookId = _bookId;
    final finished = _loadedChapterIndex;
    if (book == null || bookId == null || finished == null || _advancing) return;

    final next = finished + 1;
    if (next >= book.chapters.length) {
      if (mounted) setState(() => _status = 'Reached the end of "${book.title}"');
      return;
    }

    _advancing = true;
    try {
      // Bank the new position right away: if the app dies while the next
      // chapter is still being prepared, reopening should land at the start
      // of the next chapter, not the tail of the one just finished.
      await ReadingProgressStore.save(
        bookId: bookId,
        chapterIndex: next,
        positionMs: 0,
      );
      if (mounted) setState(() => _selectedChapterIndex = next);
      await _loadChapter(next, fromUser: false);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _togglePlayPause(PlayerState state) async {
    if (state.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
      unawaited(_player.play());
    } else if (state.playing) {
      await _player.pause();
      await _saveProgress();
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> _seekTo(Duration target) async {
    final total = _player.duration ?? Duration.zero;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await _player.seek(target);
    await _saveProgress();
  }

  Future<void> _skip(int seconds) async {
    await _seekTo(_player.position + Duration(seconds: seconds));
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  int _estimateMinutes(int chars) => (chars / 800).ceil();

  @override
  Widget build(BuildContext context) {
    final loaded = _loadedChapterIndex != null;
    final cache = _cache;
    return Scaffold(
      appBar: AppBar(title: const Text('Webnovel TTS Reader')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: (_busy || _engineReady) ? null : _initEngine,
              child: Text(_engineReady ? 'Engine initialized ✓' : '1. Initialize TTS engine'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: (_busy || !_engineReady) ? null : _pickEpub,
              child: const Text('2. Pick EPUB file'),
            ),
            const SizedBox(height: 8),
            if (_book != null) ...[
              Text(
                _book!.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_book!.author != null) Text('by ${_book!.author}'),
              const SizedBox(height: 8),
              DropdownButton<int>(
                isExpanded: true,
                hint: const Text('3. Select a chapter'),
                value: _selectedChapterIndex,
                items: [
                  for (var i = 0; i < _book!.chapters.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i + 1}. ${_book!.chapters[i].title} '
                        '(~${_estimateMinutes(_book!.chapters[i].characterCount)} min)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy ? null : (i) => setState(() => _selectedChapterIndex = i),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: (_busy || _selectedChapterIndex == null)
                    ? null
                    : () => _loadChapter(_selectedChapterIndex!),
                child: const Text('4. Play chapter'),
              ),
            ],
            const SizedBox(height: 16),
            if (_progressTotal > 0)
              LinearProgressIndicator(value: _progressDone / _progressTotal),
            const SizedBox(height: 8),
            Text(_status),
            if (cache != null)
              ValueListenableBuilder<String>(
                valueListenable: cache.backgroundStatus,
                builder: (context, text, _) => text.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          text,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
              ),
            const SizedBox(height: 24),
            if (loaded) _buildPlayerControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerControls() {
    final current = _loadedChapterIndex!;
    final chapterTitle = _book!.chapters[current].title;
    final hasPrevious = current > 0;
    final hasNext = current < _book!.chapters.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          chapterTitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        StreamBuilder<Duration?>(
          stream: _player.durationStream,
          builder: (context, durationSnap) {
            final total = durationSnap.data ?? Duration.zero;
            return StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, positionSnap) {
                var position = positionSnap.data ?? Duration.zero;
                if (position > total) position = total;
                final remaining = total - position;
                final maxMs = total.inMilliseconds > 0
                    ? total.inMilliseconds.toDouble()
                    : 1.0;
                final valueMs = (_dragValueMs ?? position.inMilliseconds.toDouble())
                    .clamp(0.0, maxMs);
                return Column(
                  children: [
                    Slider(
                      value: valueMs,
                      max: maxMs,
                      onChanged: total == Duration.zero
                          ? null
                          : (v) => setState(() => _dragValueMs = v),
                      onChangeEnd: (v) async {
                        setState(() => _dragValueMs = null);
                        await _seekTo(Duration(milliseconds: v.round()));
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(Duration(milliseconds: valueMs.round()))),
                          Text('-${_fmt(remaining)} left'),
                          Text(_fmt(total)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 8),
        StreamBuilder<PlayerState>(
          stream: _player.playerStateStream,
          builder: (context, snap) {
            final state = snap.data ?? PlayerState(false, ProcessingState.idle);
            final completed = state.processingState == ProcessingState.completed;
            final icon = completed
                ? Icons.replay
                : (state.playing ? Icons.pause : Icons.play_arrow);
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 32,
                  tooltip: 'Previous chapter',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: hasPrevious ? () => _loadChapter(current - 1) : null,
                ),
                IconButton(
                  iconSize: 40,
                  tooltip: 'Back $_skipSeconds seconds',
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => _skip(-_skipSeconds),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  iconSize: 56,
                  tooltip: state.playing ? 'Pause' : 'Play',
                  icon: Icon(icon),
                  onPressed: () => _togglePlayPause(state),
                ),
                const SizedBox(width: 8),
                IconButton(
                  iconSize: 40,
                  tooltip: 'Forward $_skipSeconds seconds',
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => _skip(_skipSeconds),
                ),
                IconButton(
                  iconSize: 32,
                  tooltip: 'Next chapter',
                  icon: const Icon(Icons.skip_next),
                  onPressed: hasNext ? () => _loadChapter(current + 1) : null,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}