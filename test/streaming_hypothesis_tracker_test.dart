import 'package:test/test.dart';

import 'package:iko_classroom/services/asr/streaming_hypothesis_tracker.dart';

void main() {
  test('周期性确认只提交新增内容，不要求重置解码器', () {
    final tracker = StreamingHypothesisTracker();

    expect(tracker.observe('老师今天讲'), '老师今天讲');
    expect(tracker.commit(), '老师今天讲');
    expect(tracker.observe('老师今天讲到第二章'), '到第二章');
    expect(tracker.commit(), '到第二章');
    expect(tracker.observe('老师今天讲到第二章和第三章'), '和第三章');
  });

  test('真实 final 结束后，下一段重新从完整假设开始', () {
    final tracker = StreamingHypothesisTracker();

    tracker.observe('上一句话');
    expect(tracker.finish('上一句话已经结束'), '上一句话已经结束');
    expect(tracker.observe('下一句话'), '下一句话');
  });
}
