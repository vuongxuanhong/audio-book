import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// A book's cover: the server's image when it has one (cached on disk), and
/// otherwise — or while it loads, or if it fails — a generated one, so a
/// shelf of books without covers still tells them apart at a glance.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.title,
    this.url,
    this.radius = 6,
  });

  final String title;
  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final generated = GeneratedCover(title: title);
    final url = this.url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? generated
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, _) => generated,
              errorWidget: (_, _, _) => generated,
              fadeInDuration: const Duration(milliseconds: 150),
            ),
    );
  }
}

/// A stand-in cover: a muted colour picked from the title (so a book always
/// gets the same one) with the title set on it — or just its first letter
/// when the cover is too small for words.
class GeneratedCover extends StatelessWidget {
  const GeneratedCover({super.key, required this.title});

  final String title;

  /// Deep enough for white text on any of them, in light and dark mode.
  static const _palette = <Color>[
    Color(0xFF5B4B8A),
    Color(0xFF2F6F73),
    Color(0xFF8A4B4B),
    Color(0xFF3F5F86),
    Color(0xFF7A5C2E),
    Color(0xFF3E6B48),
    Color(0xFF6B3E66),
    Color(0xFF4A5568),
  ];

  /// Stable across runs (unlike [String.hashCode]).
  static Color colorFor(String title) {
    var hash = 0;
    for (final unit in title.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _palette[hash % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final base = colorFor(title);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, Color.lerp(base, Colors.black, 0.35)!],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final small = constraints.maxWidth < 80;
          final text = title.trim();
          return Center(
            child: Padding(
              padding: EdgeInsets.all(small ? 4 : 12),
              child: Text(
                small
                    ? (text.isEmpty ? '' : text.characters.first.toUpperCase())
                    : text,
                textAlign: TextAlign.center,
                maxLines: small ? 1 : 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: small
                      ? constraints.maxWidth * 0.45
                      : constraints.maxWidth * 0.11,
                  height: 1.25,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
