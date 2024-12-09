// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data'; // for Uint8List
import 'dart:math' as math;

import 'package:dart_melty_soundfont/preset.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:flutter/material.dart';

import 'package:dart_melty_soundfont/synthesizer.dart';
import 'package:dart_melty_soundfont/synthesizer_settings.dart';
import 'package:dart_melty_soundfont/audio_renderer_ex.dart';
import 'package:flutter_piano_pro/flutter_piano_pro.dart';
import 'package:flutter_piano_pro/note_model.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

String asset = 'assets/Zemer.sf2';
int sampleRate = 44100;

void main() => runApp(const MeltyApp());

class MeltyApp extends StatefulWidget {
  const MeltyApp({Key? key}) : super(key: key);

  @override
  State<MeltyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MeltyApp> {
  Synthesizer? _synth;

  late AudioStream _audioStream;

  bool _isPlaying = false;
  bool _soundFontLoaded = false;

  Map<int, NoteModel> pointerAndNote = {};

  int _feedCount = 0;

  final balanceAmount = 60 * sampleRate * 2 ~/ 1000;

  @override
  void initState() {
    super.initState();
    _audioStream = getAudioStream();
    _audioStream.init(
      channels: 2,
      waitingBufferMilliSec: 30,
      bufferMilliSec: 100,
    );

    // DartMeltySoundfont
    _loadSoundfont().then((_) {
      _soundFontLoaded = true;
      setState(() {});
    });
  }

  Future<void> _loadSoundfont() async {
    ByteData bytes = await rootBundle.load(asset);
    _synth = Synthesizer.loadByteData(bytes, SynthesizerSettings());

    // print available instrumentsk
    List<Preset> p = _synth!.soundFont.presets;
    for (int i = 0; i < p.length; i++) {
      String instrumentName =
          p[i].regions.isNotEmpty ? p[i].regions[0].instrument.name : "N/A";
      print('[preset $i] name: ${p[i].name} instrument: $instrumentName');
    }

    return Future<void>.value(null);
  }

  Timer? _timer;
  Timer? _timer2;

  var lastBufferCount = 0;

  @override
  void dispose() {
    _audioStream.uninit();
    super.dispose();
  }

  int _exhaust = 0;
  int _full = 0;

  int beat = 0;

  void _push() {
    _feedCount++;
    if (_feedCount % 50 == 0) {
      var stats = _audioStream.stat();
      _exhaust = stats.exhaust;
      _full = stats.full;
      setState(() {});
    }
    var amountToSend = math.max(100, balanceAmount - lastBufferCount);
    amountToSend = math.min(amountToSend, 2000);
    var buf = List<double>.filled(amountToSend, 0);
    _synth!.renderInterleaved(buf);
    var newLastCount = _audioStream.push(Float32List.fromList(buf));
    var usedAmount = lastBufferCount + amountToSend - newLastCount;
    lastBufferCount = newLastCount;
    //print(
    //    'used $usedAmount, in buffer: ${lastBufferCount - amountToSend}, pushed $amountToSend');
  }

  Future<void> _play() async {
    setState(() {
      _audioStream.resetStat();
      _exhaust = 0;
      _full = 0;

      _isPlaying = true;
    });
    _feedCount = 1;
    _timer = Timer.periodic(Duration(milliseconds: 8), (Timer t) async {
      _push();
    });

    _timer2 = Timer.periodic(Duration(milliseconds: 300), (Timer t) async {
      beat++;
      _synth!.noteOn(channel: 1, key: 44, velocity: 120);
      _synth!.noteOff(channel: 1, key: 44);

      if (beat % 4 == 0) {
        _synth!.noteOn(channel: 1, key: 38, velocity: 127);
        _synth!.noteOff(channel: 1, key: 38);
      } else if (beat % 4 == 2) {
        _synth!.noteOn(channel: 1, key: 40, velocity: 127);
        _synth!.noteOff(channel: 1, key: 40);
      }
    });

    _synth!.noteOffAll();
    _synth!.selectPreset(channel: 1, preset: 9);
    _synth!.selectPreset(channel: 0, preset: 0);
  }

  Future<void> _pause() async {
    _timer?.cancel();
    _timer = null;
    _timer2?.cancel();
    _timer2 = null;
    setState(() {
      _isPlaying = false;
    });
  }

  Future<void> playNote({required int key}) async {
    if (!_isPlaying) return;
    _synth!.noteOn(channel: 0, key: key, velocity: 127);
    for (var i in [7, 12, 15, 19]) {
      await Future.delayed(Duration(milliseconds: 4));
      _synth!.noteOn(channel: 0, key: key + i, velocity: 127);
    }
  }

  /// Stops a note on the specified channel.
  void stopNote({required int key}) {
    _synth!.noteOff(channel: 0, key: key);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (!_soundFontLoaded) {
      child = const Text("initializing...");
    } else {
      child = Center(
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: ElevatedButton(
                    child: Text(_isPlaying ? "Pause" : "Play"),
                    onPressed: () => _isPlaying ? _pause() : _play(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Text("Exahst $_exhaust"),
                ),
                Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Text("Full $_full"),
                ),
              ],
            ),
            Padding(
                padding: const EdgeInsets.all(4.0),
                child: PianoPro(
                  noteCount: 15,
                  whiteHeight: 170,
                  onTapDown: (NoteModel? note, int tapId) {
                    if (note == null) return;
                    pointerAndNote[tapId] = note;
                    playNote(
                      key: note.midiNoteNumber,
                    );
                    debugPrint(
                        'DOWN: note= ${note.name + note.octave.toString() + (note.isFlat ? "♭" : '')}, tapId= $tapId');
                  },
                  onTapUpdate: (NoteModel? note, int tapId) {
                    if (note == null) return;
                    if (pointerAndNote[tapId] == note) return;
                    stopNote(
                      key: pointerAndNote[tapId]!.midiNoteNumber,
                    );
                    pointerAndNote[tapId] = note;
                    playNote(
                      key: note.midiNoteNumber,
                    );
                    debugPrint(
                        'UPDATE: note= ${note.name + note.octave.toString() + (note.isFlat ? "♭" : '')}, tapId= $tapId');
                  },
                  onTapUp: (int tapId) {
                    stopNote(
                      key: pointerAndNote[tapId]!.midiNoteNumber,
                    );
                    pointerAndNote.remove(tapId);
                    debugPrint('UP: tapId= $tapId');
                  },
                ))
          ],
        ),
      );
    }
    return MaterialApp(
        home: Scaffold(
      appBar: AppBar(title: const Text('Soundfont')),
      body: child,
    ));
  }
}
