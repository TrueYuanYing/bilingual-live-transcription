import 'package:iko_classroom/services/asr/streaming_hypothesis_tracker.dart';
void main() {
  final tracker = StreamingHypothesisTracker();
  print(tracker.observe('今天介绍 Fourier transform'));
  print('快照：${tracker.commit()}');
  print('新增：${tracker.finish('今天介绍 Fourier transform 的性质')}');
}
