import 'dart:math' as math;

import 'midi_file_sequencer.dart';
import 'new_midi_file.dart';
import 'synthesizer.dart';
import 'audio_renderer.dart';
import 'list_slice.dart';

/// <summary>
/// An instance of the MIDI file sequencer.
/// </summary>
/// <remarks>
/// Note that this class does not provide thread safety.
/// If you want to control playback and render the waveform in separate threads,
/// you must make sure that the methods are not called at the same time.
/// </remarks>
class NewMidiFileSequencer implements AudioRenderer {
  final Synthesizer synthesizer;

  double _speed = 1.0;

  final NewMidiFile midiFile;
  bool? _loop;

  int _blockWrote = 0;

  Duration _currentTime = Duration.zero;
  int _msgIndex = 0;
  int _loopIndex = 0;

  MessageHook? onSendMessage;

  /// <summary>
  /// Initializes a new instance of the sequencer.
  /// </summary>
  /// <param name="synthesizer">The synthesizer to be used by the sequencer.</param>
  NewMidiFileSequencer(this.synthesizer, this.midiFile);

  /// <summary>
  /// Plays the MIDI file.
  /// </summary>
  /// <param name="midiFile">The MIDI file to be played.</param>
  /// <param name="loop">If <c>true</c>, the MIDI file loops after reaching the end.</param>
  void play({required bool loop, Duration? position}) {
    _loop = loop;

    _blockWrote = synthesizer.blockSize;
    _currentTime = position ?? Duration.zero;

    _msgIndex = 0;
    _loopIndex = 0;

    synthesizer.reset();

    if (position != null && position > Duration.zero) {
      _processEvents(skipping: true);
    }
  }

  /// <summary>
  /// Stops playing.
  /// </summary>
  void stop() {
    synthesizer.reset();
  }

  /// <inheritdoc/>
  void render(List<double> left, List<double> right) {
    if (left.length != right.length) {
      throw "The output buffers for the left and right must be the same length.";
    }

    var wrote = 0;
    while (wrote < left.length) {
      if (_blockWrote == synthesizer.blockSize) {
        _processEvents();
        _blockWrote = 0;
        _currentTime += NewMidiFile.getTimeSpanFromSeconds(
            _speed * synthesizer.blockSize / synthesizer.sampleRate);
      }

      var srcRem = synthesizer.blockSize - _blockWrote;
      var dstRem = left.length - wrote;
      var rem = math.min(srcRem, dstRem);

      synthesizer.render(left.slice(wrote, rem), right.slice(wrote, rem));

      _blockWrote += rem;
      wrote += rem;
    }
  }

  void _processEvents({bool skipping = false}) {
    while (_msgIndex < midiFile.events.length) {
      var time = midiFile.events[_msgIndex].time;
      var msg = midiFile.events[_msgIndex].message;
      if (time <= _currentTime) {
        if (msg.type == MidiMessageType.normal) {
          if (onSendMessage == null) {
            if (!skipping || (msg.command != 0x80 && msg.command != 0x90)) {
              synthesizer.processMidiMessage(
                  channel: msg.channel,
                  command: msg.command,
                  data1: msg.data1,
                  data2: msg.data2);
            }
          } else {
            onSendMessage!(
                synthesizer, msg.channel, msg.command, msg.data1, msg.data2);
          }
        } else if (_loop == true) {
          if (msg.type == MidiMessageType.loopStart) {
            _loopIndex = _msgIndex;
          } else if (msg.type == MidiMessageType.loopEnd) {
            _currentTime = midiFile.events[_loopIndex].time;
            _msgIndex = _loopIndex;
            synthesizer.noteOffAll();
          }
        }
        _msgIndex++;
      } else {
        break;
      }
    }

    if (_msgIndex == midiFile.events.length && _loop == true) {
      _currentTime = midiFile.events[_loopIndex].time;
      _msgIndex = _loopIndex;
      synthesizer.noteOffAll();
    }
  }

  /// <summary>
  /// Gets the current playback position.
  /// </summary>
  Duration get position => _currentTime;

  /// <summary>
  /// Gets a value that indicates whether the current playback position is at the end of the sequence.
  /// </summary>
  /// <remarks>
  /// If the <see cref="Play(MidiFile, bool)">Play</see> method has not yet been called, this value is true.
  /// This value will never be <c>true</c> when loop playback is enabled.
  /// </remarks>
  bool get endOfSequence {
    return _msgIndex == midiFile.events.length;
  }

  /// <summary>
  /// Gets or sets the playback speed.
  /// </summary>
  /// <remarks>
  /// The default value is 1.
  /// The tempo will be multiplied by this value.
  /// </remarks>
  double get speed => _speed;

  set speed(double value) {
    if (value >= 0) {
      _speed = value;
    } else {
      throw "The playback speed must be a non-negative value.";
    }
  }
}
