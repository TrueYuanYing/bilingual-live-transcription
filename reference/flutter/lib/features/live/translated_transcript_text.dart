import 'package:flutter/material.dart';
import '../../services/asr/mixed_language_text.dart';
import '../../core/theme/app_colors.dart';

/// Rebuilds text spans only when final text, translations, or theme changes.
class TranslatedTranscriptText extends StatefulWidget {
  const TranslatedTranscriptText(
      {super.key,
      required this.text,
      required this.style,
      required this.translations});
  final String text;
  final TextStyle style;
  final Map<String, String> translations;
  @override
  State<TranslatedTranscriptText> createState() =>
      _TranslatedTranscriptTextState();
}

class _TranslatedTranscriptTextState extends State<TranslatedTranscriptText> {
  static final _word = RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*");
  static String _wordKey(String text) => _word
      .allMatches(text)
      .map((word) => word.group(0)!.replaceAll('’', "'").toLowerCase())
      .join(' ');
  TextSpan? _cached;
  String? _text;
  Map<String, String>? _translations;
  TextStyle? _style;
  Brightness? _brightness;
  static List<TextSpan> translatedSpans(String text, TextStyle style,
      Map<String, String> translations, Brightness brightness) {
    final translatedByWords = {
      for (final entry in translations.entries)
        if (_wordKey(entry.key).isNotEmpty) _wordKey(entry.key): entry.value
    };
    final keys = translatedByWords.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final pattern = keys.isEmpty
        ? null
        : RegExp(
            '(?<![A-Za-z0-9])(?:${keys.map((key) => key.split(' ').map((word) => RegExp.escape(word).replaceAll("'", "['’]")).join(r'[\s,.;:!?，。！？；：、"“”()\[\]-]+')).join('|')})[.!?,;:]*(?![A-Za-z0-9])',
            caseSensitive: false);
    final spans = <TextSpan>[];
    for (final span in MixedLanguageText.spans(text)) {
      spans.add(TextSpan(text: span.text, style: style));
      if (span.language != TranscriptSpanLanguage.english || pattern == null) {
        continue;
      }
      spans.removeLast();
      var offset = 0;
      for (final match in pattern.allMatches(span.text)) {
        spans.add(TextSpan(
            text: span.text.substring(offset, match.end), style: style));
        spans.add(TextSpan(
            text: '（${translatedByWords[_wordKey(match.group(0)!)]}）',
            style: style.copyWith(
                color: brightness == Brightness.dark
                    ? AppColors.translationDark
                    : AppColors.translationLight)));
        offset = match.end;
      }
      spans.add(TextSpan(text: span.text.substring(offset), style: style));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (_cached == null ||
        _text != widget.text ||
        !identical(_translations, widget.translations) ||
        _style != widget.style ||
        _brightness != brightness) {
      _cached = TextSpan(
          children: translatedSpans(
              widget.text, widget.style, widget.translations, brightness));
      _text = widget.text;
      _translations = widget.translations;
      _style = widget.style;
      _brightness = brightness;
    }
    return RichText(
        text: _cached!, textScaler: MediaQuery.textScalerOf(context));
  }
}

/// A full classroom remains scrollable, but only visible short paragraphs get
/// laid out. Annotation is resolved before splitting, so a long English source
/// can cross a display boundary without losing its adjacent translation.
class TranslatedTranscriptSliver extends StatefulWidget {
  const TranslatedTranscriptSliver(
      {super.key,
      required this.text,
      required this.style,
      required this.translations});
  final String text;
  final TextStyle style;
  final Map<String, String> translations;
  @override
  State<TranslatedTranscriptSliver> createState() =>
      _TranslatedTranscriptSliverState();
}

class _TranslatedTranscriptSliverState
    extends State<TranslatedTranscriptSliver> {
  String? _text;
  TextStyle? _style;
  Map<String, String>? _translations;
  Brightness? _brightness;
  TextScaler? _scaler;
  List<Widget> _paragraphs = [];
  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness,
        scaler = MediaQuery.textScalerOf(context);
    if (_text != widget.text ||
        _style != widget.style ||
        !identical(_translations, widget.translations) ||
        _brightness != brightness ||
        _scaler != scaler) {
      final groups = <List<TextSpan>>[], current = <TextSpan>[];
      var length = 0;
      for (final span in _TranslatedTranscriptTextState.translatedSpans(
          widget.text, widget.style, widget.translations, brightness)) {
        final text = span.text ?? '';
        var offset = 0;
        while (offset < text.length) {
          var end = (offset + 600 - length).clamp(offset, text.length);
          if (end < text.length && end > offset) {
            final unit = text.codeUnitAt(end);
            if (unit >= 0xdc00 && unit <= 0xdfff) end--;
            final window = text.substring(offset, end),
                newline = window.lastIndexOf('\n');
            if (newline >= 100) end = offset + newline + 1;
          }
          if (end == offset) {
            groups.add(List.of(current));
            current.clear();
            length = 0;
            continue;
          }
          current.add(
              TextSpan(text: text.substring(offset, end), style: span.style));
          length += end - offset;
          offset = end;
          if (length >= 598 || offset < text.length) {
            groups.add(List.of(current));
            current.clear();
            length = 0;
          }
        }
      }
      if (current.isNotEmpty) groups.add(current);
      _paragraphs = [
        for (final spans in groups)
          RichText(text: TextSpan(children: spans), textScaler: scaler)
      ];
      _text = widget.text;
      _style = widget.style;
      _translations = widget.translations;
      _brightness = brightness;
      _scaler = scaler;
    }
    return SliverList(
        delegate: SliverChildBuilderDelegate(
            (context, index) => _paragraphs[index],
            childCount: _paragraphs.length,
            addAutomaticKeepAlives: false));
  }
}
