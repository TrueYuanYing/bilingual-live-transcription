import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:iko_classroom/services/audio/stereo_pcm_decimator.dart';

Uint8List stereoTone(double frequency, {int frames = 48000}) {
  final bytes = Uint8List(frames * 4);
  for (var i = 0; i < frames; i++) {
    final value =
        (10000 * math.sin(2 * math.pi * frequency * i / 48000)).round();
    for (final offset in [0, 2]) {
      bytes[i * 4 + offset] = value & 0xff;
      bytes[i * 4 + offset + 1] = (value >> 8) & 0xff;
    }
  }
  return bytes;
}

double rms(Uint8List bytes, {int skip = 100}) {
  var sum = 0.0;
  var count = 0;
  for (var i = skip * 2; i + 1 < bytes.length; i += 2) {
    final sample = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16);
    sum += sample * sample;
    count++;
  }
  return math.sqrt(sum / count);
}

void main() {
  test('arbitrary chunk boundaries produce identical 16 kHz PCM', () {
    final input = stereoTone(1000);
    final entire = StereoPcmDecimator().convert(input);
    final chunked = StereoPcmDecimator();
    final builder = BytesBuilder();
    var offset = 0;
    for (final size in [1, 2, 7, 127, 1024, input.length]) {
      if (offset >= input.length) break;
      final end = math.min(input.length, offset + size);
      builder.add(chunked.convert(Uint8List.sublistView(input, offset, end)));
      offset = end;
    }
    expect(builder.takeBytes(), orderedEquals(entire));
    expect(entire.length, 16000 * 2);
    expect(rms(entire), closeTo(7071, 150));
  });

  test('high-frequency content is filtered before decimation', () {
    final speech = StereoPcmDecimator().convert(stereoTone(1000));
    final alias = StereoPcmDecimator().convert(stereoTone(12000));
    expect(rms(alias), lessThan(rms(speech) * 0.08));
  });
}
