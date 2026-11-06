import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../notes/notes_live_text.dart';

/// Short split panes scroll their metadata with the transcript. Capture controls
/// are owned by the parent, outside the native notes rectangle.
class CaptureTranscriptViewport extends StatelessWidget {
  const CaptureTranscriptViewport(
      {super.key,
      required this.before,
      required this.after,
      required this.builder});
  final List<Widget> before, after;
  final Widget Function(List<Widget>, List<Widget>) builder;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        if (after.isEmpty) return builder(before, const []);
        return Column(children: [
          Expanded(child: builder(before, const [])),
          ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight *
                      (constraints.maxHeight < 360 ? .7 : .5)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final child in after) Flexible(child: child),
              ])),
        ]);
      });
}

/// Both children remain the same objects while a divider moves or orientation changes.
class ClassroomNotesSplit extends StatefulWidget {
  const ClassroomNotesSplit(
      {super.key,
      required this.transcript,
      required this.notes,
      required this.onClose,
      this.onExpand});
  final Widget transcript, notes;
  final VoidCallback onClose;
  final VoidCallback? onExpand;
  @override
  State<ClassroomNotesSplit> createState() => _ClassroomNotesSplitState();
}

class _ClassroomNotesSplitState extends State<ClassroomNotesSplit> {
  double _horizontal = 0.44, _vertical = 0.44;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final screen = MediaQuery.sizeOf(context);
        final horizontal =
            screen.shortestSide >= 600 || screen.width > screen.height;
        final extent =
            horizontal ? constraints.maxWidth : constraints.maxHeight;
        final minimum = horizontal ? 260.0 : 170.0;
        final lower = (minimum / extent).clamp(0.25, 0.44), upper = 1 - lower;
        final fraction =
            (horizontal ? _horizontal : _vertical).clamp(lower, upper);
        void move(DragUpdateDetails details) {
          setState(() {
            final next = (fraction +
                    (horizontal ? details.delta.dx : details.delta.dy) / extent)
                .clamp(lower, upper);
            if (horizontal) {
              _horizontal = next;
            } else {
              _vertical = next;
            }
          });
        }

        final notes = Column(children: [
          SizedBox(
              height: 44,
              child: Row(children: [
                const SizedBox(width: 12),
                Expanded(
                    child: Text('课堂笔记',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall)),
                if (widget.onExpand != null)
                  IconButton(
                      tooltip: '展开笔记',
                      icon: const Icon(Icons.open_in_full_rounded, size: 18),
                      onPressed: widget.onExpand),
                IconButton(
                    tooltip: '收起笔记',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: widget.onClose),
              ])),
          const NotesLiveTextStrip(),
          Expanded(child: widget.notes),
        ]);
        final dividerWidth = horizontal ? 20.0 : 18.0;
        final divider = Semantics(
            label: '拖动调整听写与笔记比例',
            child: MouseRegion(
                cursor: horizontal
                    ? SystemMouseCursors.resizeColumn
                    : SystemMouseCursors.resizeRow,
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: horizontal ? move : null,
                    onVerticalDragUpdate: horizontal ? null : move,
                    child: SizedBox(
                        width: horizontal ? dividerWidth : double.infinity,
                        height: horizontal ? double.infinity : 18,
                        child: horizontal
                            ? Center(
                                child: Container(
                                    width: 3,
                                    height: 42,
                                    decoration: BoxDecoration(
                                        color: AppColors.separator(
                                            Theme.of(context).brightness),
                                        borderRadius:
                                            BorderRadius.circular(2))))
                            : Center(
                                child: Container(
                                    width: 42,
                                    height: 3,
                                    color: AppColors.separator(
                                        Theme.of(context).brightness)))))));
        return Flex(
            direction: horizontal ? Axis.horizontal : Axis.vertical,
            children: [
              SizedBox(
                  width: horizontal ? (extent - dividerWidth) * fraction : null,
                  height:
                      horizontal ? null : (extent - dividerWidth) * fraction,
                  child: widget.transcript),
              divider,
              Expanded(child: notes),
            ]);
      });
}
