import 'dart:math' as math;
import 'dart:typed_data';

/// Converts interleaved 48 kHz stereo PCM16 to 16 kHz mono PCM16.
///
/// The low-pass FIR runs before decimation to avoid folding high-frequency
/// noise into speech. State is retained across arbitrary recorder chunks.
class StereoPcmDecimator {
  static const int _tapCount = 63;
  static final Float64List _taps = _designTaps();

  final Float64List _left = Float64List(_tapCount);
  final Float64List _right = Float64List(_tapCount);
  final Uint8List _pending = Uint8List(4);
  int _pendingLength = 0;
  int _position = 0;
  int _phase = 0;

  Uint8List convert(Uint8List input) {
    final output = Uint8List(((input.length + _pendingLength) ~/ 12 + 1) * 2);
    var outputLength = 0;
    for (final byte in input) {
      _pending[_pendingLength++] = byte;
      if (_pendingLength != 4) continue;
      _pendingLength = 0;
      final l = (_pending[0] | (_pending[1] << 8)).toSigned(16);
      final r = (_pending[2] | (_pending[3] << 8)).toSigned(16);
      _left[_position] = l.toDouble();
      _right[_position] = r.toDouble();
      _position = (_position + 1) % _tapCount;
      if (++_phase != 3) continue;
      _phase = 0;
      var sample = 0.0;
      for (var tap = 0; tap < _tapCount; tap++) {
        final index = (_position + tap) % _tapCount;
        sample += _taps[tap] * (_left[index] + _right[index]) * 0.5;
      }
      final pcm = sample.round().clamp(-32768, 32767);
      output[outputLength++] = pcm & 0xff;
      output[outputLength++] = (pcm >> 8) & 0xff;
    }
    return Uint8List.sublistView(output, 0, outputLength);
  }

  static Float64List _designTaps() {
    final coefficients = Float64List(_tapCount);
    const cutoff = 7000.0 / 48000.0;
    var sum = 0.0;
    for (var i = 0; i < _tapCount; i++) {
      final offset = i - (_tapCount - 1) / 2;
      final sinc = offset == 0
          ? 2 * cutoff
          : math.sin(2 * math.pi * cutoff * offset) / (math.pi * offset);
      final window = 0.54 - 0.46 * math.cos(2 * math.pi * i / (_tapCount - 1));
      coefficients[i] = sinc * window;
      sum += coefficients[i];
    }
    for (var i = 0; i < _tapCount; i++) {
      coefficients[i] /= sum;
    }
    return coefficients;
  }
}
