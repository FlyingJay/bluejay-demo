import 'package:flutter/material.dart';

/// Selectable text that screen readers can read.
///
/// Use this instead of [SelectableText]. A [SelectableText] is a read-only
/// text field, and on the web its text never reaches the semantics tree: a
/// screen reader finds an empty field, and so does anything that reads the
/// page through its accessibility tree (the store screenshot runner, for
/// one). A plain [Text] inside a [SelectionArea] is just as selectable and
/// is read like any other text.
///
/// Takes the [SelectableText] parameters bluejay uses, so swapping one for
/// the other is a rename. For Markdown, wrap the widget in a [SelectionArea]
/// and leave its own `selectable` off, for the same reason.
class ReadableSelectableText extends StatelessWidget {
  const ReadableSelectableText(
    String this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
  }) : textSpan = null;

  const ReadableSelectableText.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final text = textSpan == null
        ? Text(data!, style: style, textAlign: textAlign, maxLines: maxLines)
        : Text.rich(textSpan!,
            style: style, textAlign: textAlign, maxLines: maxLines);
    return SelectionArea(child: text);
  }
}
