import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// A book's saved listening position: which chapter, and how far into that
/// chapter's synthesized audio (in milliseconds).
class ReadingProgress {
  final int chapterIndex;
  final int positionMs;

  ReadingProgress({required this.chapterIndex, required this.positionMs});
}

/// Persists and restores per-book listening progress across app restarts.
///
/// Stores plain Maps (natively supported by Hive) rather than custom
/// objects, so no generated type adapters are needed for something this
/// small.
class ReadingProgressStore {
  static const _boxName = 'reading_progress';

  /// Call once at app startup, before runApp.
  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(_boxName);
  }

  static Box get _box => Hive.box(_boxName);

  static Future<void> save({
    required String bookId,
    required int chapterIndex,
    required int positionMs,
  }) async {
    await _box.put(bookId, {
      'chapterIndex': chapterIndex,
      'positionMs': positionMs,
    });
  }

  /// Returns saved progress for [bookId], or null if none exists yet.
  static ReadingProgress? load(String bookId) {
    final raw = _box.get(bookId);
    if (raw == null) return null;
    final map = Map<String, dynamic>.from(raw as Map);
    return ReadingProgress(
      chapterIndex: map['chapterIndex'] as int,
      positionMs: map['positionMs'] as int,
    );
  }

  static Future<void> clear(String bookId) async {
    await _box.delete(bookId);
  }
}