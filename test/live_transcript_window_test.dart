import 'package:test/test.dart';

import 'package:iko_classroom/services/asr/live_transcript_window.dart';
import 'package:iko_classroom/services/asr/transcript_refiner.dart';

void main() {
  test('听写页只排版最近窗口，但保留结尾且不修改完整正文', () {
    final full = List<String>.generate(9000, (i) => '${i % 10}').join();

    final visible = LiveTranscriptWindow.tail(full, maxCharacters: 1200);

    expect(visible.length, lessThanOrEqualTo(1202));
    expect(visible, startsWith('…\n'));
    expect(visible, endsWith(full.substring(full.length - 1200)));
    expect(full.length, 9000);
  });

  test('本地智能整理可分句分段，关闭时不改原文', () {
    const raw = '第一句已经结束。第二句继续说明！第三句是补充内容。';
    final refined = LocalTranscriptRefiner.refine(raw);

    expect(refined, contains('结束。\n'));
    expect(refined, contains('说明！'));
    expect(LocalTranscriptRefiner.refine('没有标点的原文'), '没有标点的原文');
  });

  test('阅读历史时不应因为新字到来自动跟随到底部', () {
    final policy = LiveTranscriptFollowPolicy();

    expect(policy.update(offset: 80, maxExtent: 1000), isFalse);
    expect(policy.followLatest, isFalse);
    expect(policy.showReturnToLatest, isTrue);
    expect(policy.update(offset: 950, maxExtent: 1000), isTrue);
    expect(policy.followLatest, isTrue);
    expect(policy.showReturnToLatest, isFalse);
  });
}
