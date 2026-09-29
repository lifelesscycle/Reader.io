import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Computes a stable identifier for a book from its raw EPUB bytes.
///
/// A filename-based ID breaks the moment a file is renamed or re-downloaded
/// under a different name, which would orphan the saved reading position
/// and every cached chapter. Hashing the actual content means the same
/// book is always recognized, wherever it lives and whatever it's called.
String computeBookId(Uint8List bytes) {
  final digest = sha256.convert(bytes);
  // The full 64-char SHA-256 hex is overkill for a personal library; 16 hex
  // chars (64 bits) makes collisions practically impossible at this scale
  // and keeps storage keys / cache filenames short.
  return digest.toString().substring(0, 16);
}