import 'package:flutter/material.dart';

/// The answer scrolls inside its actual pane; actions never join that scroll.
class AnswerCardLayout extends StatelessWidget {
  const AnswerCardLayout(
      {super.key, required this.content, required this.actions});
  final Widget content, actions;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, limits) {
        final body = SingleChildScrollView(child: content);
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (limits.hasBoundedHeight) Flexible(child: body) else body,
          actions,
        ]);
      });
}
