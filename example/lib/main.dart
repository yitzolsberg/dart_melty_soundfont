// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math';
import 'dart:typed_data'; // for Uint8List
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'package:flutter/material.dart';

import 'package:flutter_piano_pro/note_model.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

/*Notes:

JJazzLab should be set to output to G

*/
int sampleRate = 48000;

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

  List<(int, String)> presets = [];

  int _feedCount = 0;

  final balanceAmount = 120 * sampleRate * 2 ~/ 1000;

  List<String> soundFonts = [];
  List<String> midis = [];

  String selectedSoundFont = '';
  String selectedMidi = '';

  @override
  void initState() {
    AssetManifest.loadFromAssetBundle(rootBundle).then((manifest) {
      soundFonts = manifest
          .listAssets()
          .where((string) => string.toLowerCase().endsWith(".sf2"))
          .toList();

      selectedSoundFont = soundFonts[0];
      _selectSoundFont(selectedSoundFont);
      midis = manifest
          .listAssets()
          .where((string) => string.endsWith(".mid"))
          .toList();

      selectedMidi = midis[0];
      setState(() {});
    });

    super.initState();
    _audioStream = getAudioStream();
    _audioStream.init(
      channels: 2,
      waitingBufferMilliSec: 30,
      bufferMilliSec: 300,
    );
  }

  void _selectSoundFont(String value) {
    _soundFontLoaded = false;
    selectedSoundFont = value;
    setState(() {});
    _loadSoundfont(value).then((_) {
      _soundFontLoaded = true;
      setState(() {});
    });
  }

  void _selectMidi(String value) {
    _pauseMidi();
    selectedMidi = value;
    setState(() {});
  }

  Future<void> _loadSoundfont(String value) async {
    ByteData bytes = await rootBundle.load(value);
    _synth = Synthesizer.loadByteData(bytes, SynthesizerSettings());

    List<Preset> p = _synth!.soundFont.presets;
    presets = [];
    for (int i = 0; i < p.length; i++) {
      var instrumentName =
          p[i].regions.isNotEmpty ? p[i].regions[0].instrument.name : "N/A";
      presets.add((i, '${p[i].name} ($instrumentName)'));
    }
    selectedPreset = presets[0];
    setState(() {});

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

  MidiFileSequencer? _sequencer;

  bool _isMidiPlaying = false;

  DateTime? _started;

  Future<void> _playMidi() async {
    _synth!.noteOffAll();
    ByteData midiBytes = await rootBundle.load(selectedMidi);
    MidiFile midiFile = MidiFile.fromByteData(midiBytes);
    print(midiFile.events.map((e) => e.toString()).join('\n'));
    _isMidiPlaying = true;
    setState(() {});
    _synth!.masterVolume = 1.5;
    _sequencer = MidiFileSequencer(_synth!);

    // _sequencer!.onSendMessage = (synth, a, b, c, d) {
    //   var command = switch (b) {
    //     0x80 => 'NoteOff',
    //     0x90 => 'NoteOn',
    //     0xB0 => 'ControlChange',
    //     0xC0 => 'ProgramChange',
    //     _ => 'COM' + b.toRadixString(16)
    //   };

    //   var data1 = switch ((b, c)) {
    //     (0xB0, 0x00) => 'SetBank',
    //     (0xB0, 0x07) => 'Volume',
    //     (0xB0, 0x0A) => 'Pan',
    //     (0xB0, 0x40) => 'Sustain',
    //     (0xB0, 0x43) => 'Soft',
    //     (0xB0, 0x5B) => 'Release',
    //     (0xB0, 0x5D) => 'ChorusSend',
    //     (0xB0, 0x78) => 'AllSoundOff',
    //     (0xB0, 0x79) => 'ResetAllControllers',
    //     (0xB0, 0x7B) => 'AllNotesOff',
    //     (0xB0, _) => 'CC' + c.toRadixString(16),
    //     (_, _) => c.toString()
    //   };

    //   print('CH $a $command $data1 $d');
    // };
    _sequencer!.play(midiFile, loop: false);

    _timer = Timer.periodic(Duration(milliseconds: 10), (Timer t) async {
      _pushMidi();
    });
  }

  Duration? _lastDuration;

  Future<void> _pauseMidi() async {
    _lastDuration = _sequencer?.position;
    _sequencer?.stop();
    _timer?.cancel();
    _isMidiPlaying = false;
    setState(() {});
  }

  Future<void> _playChord(List<int> chord, [bool back = false]) async {
    var noteNum = 0;
    for (var note in (back ? chord.reversed.skip(chord.length - 3) : chord)) {
      print('play note $note');
      await _playNote(key: note, velocity: 0.5 + rand.nextDouble() * 0.2);
      noteNum++;
      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  var am = [57, 64, 69, 72, 76];
  var dm = [62, 69, 74, 77];
  var e = [59, 62, 67, 74, 79];

  late var barNumber = 0;

  var rand = Random();

  void _pushMidi() {
    _feedCount++;
    if (_feedCount % 50 == 0) {
      var stats = _audioStream.stat();
      _exhaust = stats.exhaust;
      _full = stats.full;
      setState(() {});
    }
    var amountToSend = math.max(0, balanceAmount - lastBufferCount);
    amountToSend = math.min(amountToSend, 2000);
    var buf = List<double>.filled(amountToSend, 0);
    _sequencer!.renderInterleaved(buf);
    var newLastCount = _audioStream.push(Float32List.fromList(buf));
    var currentTime = _sequencer!.position;
    var adjustment = newLastCount * 500000 ~/ sampleRate;
    var editidCurrentTime = currentTime - Duration(microseconds: adjustment);
    if (_started == null) _started = DateTime.now();

    var currentTime2 = DateTime.now().difference(_started!);

    // print(
    //     'current: ${currentTime.inMilliseconds} - ${adjustment/1000} = ${editidCurrentTime.inMilliseconds} '
    //     'current2: ${currentTime2.inMilliseconds} '
    //             'diff: ${(currentTime2 - editidCurrentTime).inMilliseconds} '

    //     'buffer: $newLastCount, pushed $amountToSend '
    //     );

    lastBufferCount = newLastCount;
  }

  var pattern = <bool?>[false, true, null, true, false, true, false, true];

  void _playReleventChord() {
    var chord = switch ((barNumber % 4)) {
      0 => am,
      1 => dm,
      2 => e,
      _ => am,
    };

    var back = pattern[beat % 8];
    if (back == null) return;
    _playChord(chord, back);
  }

  Future<void> _play() async {
    setState(() {
      _audioStream.resetStat();
      _exhaust = 0;
      _full = 0;

      _isPlaying = true;
    });
    _feedCount = 1;
    _timer = Timer.periodic(Duration(milliseconds: 5), (Timer t) async {
      _push();
    });

    _timer2 = Timer.periodic(Duration(milliseconds: 400), (Timer t) async {
      beat++;
      print('beat $beat');
      _synth!.noteOn(channel: 10, key: 42, velocity: 120);
      // Future.delayed(Duration(milliseconds: 20),
      //     () => );
      _synth!.noteOff(channel: 10, key: 42);

      if (beat % 8 == 0) {
        _synth!.noteOffAll();
        barNumber++;
        print('bar $barNumber');
      }
      if (beat % 4 == 0) {
        _synth!.noteOn(channel: 10, key: 35, velocity: 120);
        _synth!.noteOff(channel: 10, key: 35);
        // Future.delayed(Duration(milliseconds: 20),
        //     () => );
      } else if (beat % 4 == 2) {
        _synth!.noteOn(channel: 10, key: 38, velocity: 120);
        Future.delayed(Duration(milliseconds: 20),
            () => _synth!.noteOff(channel: 10, key: 38));
      }
      _playReleventChord();
    });

    _synth!.noteOffAll();
    _synth!.selectPreset(channel: 10, preset: 135); //Drums
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

  (int, String)? selectedPreset;

  void _selectPreset((int, String) value) {
    selectedPreset = value;
    _synth!.selectPreset(channel: 0, preset: value.$1);
    setState(() {});
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
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<(int, String)>(
                  value: selectedPreset,
                  icon: const Icon(Icons.arrow_downward),
                  elevation: 16,
                  style: const TextStyle(color: Colors.deepPurple),
                  underline: Container(
                    height: 2,
                    color: Colors.deepPurpleAccent,
                  ),
                  onChanged: ((int, String)? value) {
                    // This is called when the user selects an item.
                    _selectPreset(value!);
                  },
                  items: presets.map<DropdownMenuItem<(int, String)>>(
                      ((int, String) value) {
                    return DropdownMenuItem<(int, String)>(
                      value: value,
                      child: Text(value.$2),
                    );
                  }).toList(),
                ),
                DropdownButton<String>(
                  value: selectedSoundFont,
                  icon: const Icon(Icons.arrow_downward),
                  elevation: 16,
                  style: const TextStyle(color: Colors.deepPurple),
                  underline: Container(
                    height: 2,
                    color: Colors.deepPurpleAccent,
                  ),
                  onChanged: (String? value) {
                    // This is called when the user selects an item.
                    _selectSoundFont(value!);
                  },
                  items:
                      soundFonts.map<DropdownMenuItem<String>>((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    );
                  }).toList(),
                ),
                DropdownButton<String>(
                  value: selectedMidi,
                  icon: const Icon(Icons.arrow_downward),
                  elevation: 16,
                  style: const TextStyle(color: Colors.deepPurple),
                  underline: Container(
                    height: 2,
                    color: Colors.deepPurpleAccent,
                  ),
                  onChanged: (String? value) {
                    // This is called when the user selects an item.
                    _selectMidi(value!);
                  },
                  items: midis.map<DropdownMenuItem<String>>((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ],
            ),
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
                  child: ElevatedButton(
                    child: Text(_isMidiPlaying ? "Pause midi" : "Play midi"),
                    onPressed: () =>
                        _isMidiPlaying ? _pauseMidi() : _playMidi(),
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

  Future<void> _playNote({required int key, double velocity = 1.0}) async {
    if (!_isPlaying) return;
    _synth!.noteOff(
      channel: 0,
      key: key - 12,
    );

    var vel = ((80 + rand.nextInt(40)) * velocity).toInt();

    _synth!.noteOn(
      channel: 0,
      key: key - 12,
      velocity: vel,
    );
  }

  /// Stops a note on the specified channel.
  void stopNote({required int key}) {
    _synth!.noteOff(channel: 0, key: key);
  }

  void _push() {
    _feedCount++;
    if (_feedCount % 50 == 0) {
      var stats = _audioStream.stat();
      _exhaust = stats.exhaust;
      _full = stats.full;
      setState(() {});
    }
    var amountToSend = math.max(100, balanceAmount - lastBufferCount);
    amountToSend = math.min(amountToSend, 10000);
    var buf = List<double>.filled(amountToSend, 0);
    _synth!.renderInterleaved(buf);
    var newLastCount = _audioStream.push(Float32List.fromList(buf));
    lastBufferCount = newLastCount;
    print('in buffer: ${lastBufferCount - amountToSend}, pushed $amountToSend');
  }
}
