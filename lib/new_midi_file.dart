import 'dart:math';
import 'dart:typed_data';

import 'binary_reader.dart';
import 'midi_file_loop_type.dart';

class MidiEventDetailsEx {
  final MidiMessage message;
  final Duration time;
  final int bar;
  final int beat;
  final int tick;
  final int songTick;

  MidiEventDetailsEx(
    this.message,
    this.time,
    this.songTick,
    this.bar,
    this.beat,
    this.tick,
  );

  @override
  String toString() {
    return "$time: [$bar:$beat:$tick] $message";
  }
}

/// <summary>
/// Represents a standard MIDI file.
/// </summary>
class NewMidiFile {
  /// <summary>
  /// The length of the MIDI file.
  /// </summary>
  Duration get length => _events.last.time;

  @override
  List<MidiEventDetailsEx> get events => _events;

  late List<MidiEventDetailsEx> _events;

  /// Loads a MIDI file from the file path.
  factory NewMidiFile.fromFile(String path,
      {int? loopPoint, MidiFileLoopType? loopType}) {
    BinaryReader reader = BinaryReader.fromFile(path);

    return NewMidiFile.fromBinaryReader(reader,
        loopPoint: loopPoint, loopType: loopType);
  }

  /// Loads a MIDI file from the byte data
  factory NewMidiFile.fromByteData(ByteData bytes,
      {int? loopPoint, MidiFileLoopType? loopType}) {
    BinaryReader reader = BinaryReader.fromByteData(bytes);

    return NewMidiFile.fromBinaryReader(reader,
        loopPoint: loopPoint, loopType: loopType);
  }

  NewMidiFile.fromBinaryReader(BinaryReader reader,
      {int? loopPoint, MidiFileLoopType? loopType}) {
    if (loopPoint != null && loopPoint < 0) {
      throw "The loop point must be a non-negative value.";
    }

    _load(reader, loopPoint ?? 0, loopType ?? MidiFileLoopType.none);
  }

  static Duration getTimeSpanFromSeconds(double value) {
    return Duration(
        microseconds: (value * Duration.microsecondsPerSecond).round());
  }

  void _load(BinaryReader reader, int loopPoint, MidiFileLoopType loopType) {
    final chunkType = reader.readFourCC();
    if (chunkType != "MThd") {
      throw "The chunk type must be 'MThd', but was '$chunkType'.";
    }

    final size = reader.readInt32BigEndian();
    if (size != 6) {
      throw "The MThd chunk has invalid data.";
    }

    final format = reader.readInt16BigEndian();
    if (!(format == 0 || format == 1)) {
      throw "The format {format} is not supported.";
    }

    final trackCount = reader.readInt16BigEndian();
    final resolution = reader.readInt16BigEndian();

    // Read all track data

    final messageListsPerChannel =
        List<List<MidiMessage>>.filled(trackCount, [], growable: false);
    final tickListsPerChannel =
        List<List<int>>.filled(trackCount, [], growable: false);

    for (int channelNum = 0; channelNum < trackCount; channelNum++) {
      final tracks = _readTrack(reader, loopType);
      messageListsPerChannel[channelNum] = tracks.messages;
      tickListsPerChannel[channelNum] = tracks.ticks;
    }

    // Insert loop point into correct place in the first channel

    if (loopPoint != 0) {
      final firstChannelTicks = tickListsPerChannel[0];
      final firstChannelMessages = messageListsPerChannel[0];

      if (loopPoint <= firstChannelTicks.last) {
        for (int i = 0; i < firstChannelTicks.length; i++) {
          if (firstChannelTicks[i] >= loopPoint) {
            firstChannelTicks.insert(i, loopPoint);
            firstChannelMessages.insert(i, MidiMessage.loopStart());
            break;
          }
        }
      } else {
        firstChannelTicks.add(loopPoint);
        firstChannelMessages.add(MidiMessage.loopStart());
      }
    }

    // Merge all tracks

    final mergedTracks =
        _mergeTracks(messageListsPerChannel, tickListsPerChannel, resolution);
    _events = mergedTracks.events;
  }

  static _MidiMessagesAndTicks _readTrack(
      BinaryReader reader, MidiFileLoopType loopType) {
    final chunkType = reader.readFourCC();
    if (chunkType != "MTrk") {
      throw "The chunk type must be 'MTrk', but was '$chunkType'.";
    }

    int end = reader.readInt32BigEndian();
    end += reader.pos;

    final messages = <MidiMessage>[];
    final ticks = <int>[];

    int tick = 0;
    int lastStatus = 0;

    while (true) {
      final delta = reader.readMidiVariablelength();
      final first = reader.readUInt8();

      try {
        tick = tick + delta;
      } catch (OverflowException) {
        throw "Long MIDI file is not supported.";
      }

      if ((first & 128) == 0) {
        final command = lastStatus & 0xF0;
        if (command == 0xC0 || command == 0xD0) {
          messages.add(MidiMessage.common(lastStatus, first));
          ticks.add(tick);
        } else {
          final data2 = reader.readUInt8();
          messages.add(MidiMessage.common(lastStatus, first, data2, loopType));
          ticks.add(tick);
        }

        continue;
      }

      switch (first) {
        case 0xF0: // System Exclusive
          _discardData(reader);
          break;

        case 0xF7: // System Exclusive
          _discardData(reader);
          break;

        case 0xFF: // Meta Event
          switch (reader.readUInt8()) {
            case 0x2F: // End of Track
              reader.readUInt8();
              messages.add(MidiMessage.endOfTrack());
              ticks.add(tick);

              // Some MIDI files may have events inserted after the EOT.
              // Such events should be ignored.
              if (reader.pos < end) {
                reader.pos = end;
              }

              return _MidiMessagesAndTicks(messages, ticks);

            case 0x51: // Tempo
              messages.add(MidiMessage.tempoChange(_readTempo(reader)));
              ticks.add(tick);
              break;

            case 0x58: // Time Signature
              var (numerator, denominator, b1, b2) = _readTimeSignature(reader);
              messages.add(
                  MidiMessage.timeSignature(numerator, denominator, b1, b2));
              ticks.add(tick);
              break;

            default:
              _discardData(reader);
              break;
          }
          break;

        default:
          final command = first & 0xF0;
          if (command == 0xC0 || command == 0xD0) {
            final data1 = reader.readUInt8();
            messages.add(MidiMessage.common(first, data1));
            ticks.add(tick);
          } else {
            final data1 = reader.readUInt8();
            final data2 = reader.readUInt8();
            messages.add(MidiMessage.common(first, data1, data2, loopType));
            ticks.add(tick);
          }
          break;
      }

      lastStatus = first;
    }
  }

  static _MidiMessagesAndTimes _mergeTracks(
      List<List<MidiMessage>> messageLists,
      List<List<int>> tickLists,
      int resolution) {
    final mergedEvents = <MidiEventDetailsEx>[];

    final indices = List<int>.filled(messageLists.length, 0, growable: false);

    int currentTick = 0;
    Duration currentTime = Duration.zero;

    double tempo = 120.0;
    int beatsPerBar = 4;
    int currentBar = 0;
    int currentBeat = 0;
    int currentTickInBeat = 0;

    while (true) {
      int minTick = 0x7fffffffffffffff; // int max value
      int minIndex = -1;
      for (int ch = 0; ch < tickLists.length; ch++) {
        if (indices[ch] < tickLists[ch].length) {
          final tick = tickLists[ch][indices[ch]];
          if (tick < minTick) {
            minTick = tick;
            minIndex = ch;
          }
        }
      }

      if (minIndex == -1) {
        break;
      }

      final nextTick = tickLists[minIndex][indices[minIndex]];
      final deltaTick = nextTick - currentTick;
      final deltaTime =
          getTimeSpanFromSeconds(60.0 / (resolution * tempo) * deltaTick);

      currentTick += deltaTick;
      currentTime += deltaTime;
      currentTickInBeat += deltaTick;
      if (currentTickInBeat >= resolution) {
        currentBeat += currentTickInBeat ~/ resolution;
        currentTickInBeat %= resolution;
        if (currentBeat >= beatsPerBar) {
          currentBar += currentBeat ~/ beatsPerBar;
          currentBeat %= beatsPerBar;
        }
      }

      final message = messageLists[minIndex][indices[minIndex]];
      if (message.type == MidiMessageType.tempoChange) {
        tempo = message.tempo;
      } else if (message.type == MidiMessageType.timeSignature) {
        beatsPerBar = message.timeSignature.$1;
      } else {
        mergedEvents.add(MidiEventDetailsEx(
          message,
          currentTime,
          currentTick,
          currentBar,
          currentBeat,
          currentTickInBeat,
        ));
      }

      indices[minIndex]++;
    }

    var sortedEvents = <MidiEventDetailsEx>[];

    var i = 0;
    while (i < mergedEvents.length) {
      var currentTick = mergedEvents[i].songTick;
      while (i < mergedEvents.length - 1 &&
          mergedEvents[i + 1].songTick == currentTick) {
        i++;
      }
      if (i > currentTick) {
        var mid = mergedEvents.sublist(currentTick, i);
        mid.sort((a, b) {
          var aIsNote = a.message.command == 0x90 || a.message.command == 0x80;
          var bIsNote = b.message.command == 0x90 || b.message.command == 0x80;
          if (aIsNote && !bIsNote) {
            return -1;
          } else if (!aIsNote && bIsNote) {
            return 1;
          } else {
            return 0;
          }
        });
        sortedEvents.addAll(mid);
      } else {
        sortedEvents.add(mergedEvents[i]);
      }
      i++;
    }

    return _MidiMessagesAndTimes(mergedEvents);
  }

  static int _readTempo(BinaryReader reader) {
    final size = reader.readMidiVariablelength();
    if (size != 3) {
      throw "Failed to read the tempo value.";
    }

    final b1 = reader.readUInt8();
    final b2 = reader.readUInt8();
    final b3 = reader.readUInt8();
    return (b1 << 16) | (b2 << 8) | b3;
  }

  static void _discardData(BinaryReader reader) {
    final size = reader.readMidiVariablelength();
    reader.pos += size;
  }

  static (int numerator, int denominator, int b1, int b2) _readTimeSignature(
      BinaryReader reader) {
    final size = reader.readMidiVariablelength();
    if (size != 4) {
      throw "Failed to read the time signature value.";
    }

    final numerator = reader.readUInt8();
    final denominator = pow(2, reader.readUInt8()).toInt();
    final b2 = reader.readUInt8();
    final b3 = reader.readUInt8();
    return (numerator, denominator, b2, b3);
  }
}

// As Dart 2.x does not have tuples (records) yet, using classes as an alternative

class _MidiMessagesAndTicks {
  final List<MidiMessage> messages;
  final List<int> ticks;

  _MidiMessagesAndTicks(this.messages, this.ticks);
}

class _MidiMessagesAndTimes {
  final List<MidiEventDetailsEx> events;

  _MidiMessagesAndTimes(this.events);
}

class MidiMessage {
  final int channel;
  final int command;
  final int data1;
  final int data2;

  MidiMessage._(this.channel, this.command, this.data1, this.data2);

  factory MidiMessage.common(int status, int data1,
      [int data2 = 0, MidiFileLoopType loopType = MidiFileLoopType.none]) {
    final channel = status & 0x0F;
    final command = status & 0xF0;

    if (command == 0xB0) {
      switch (loopType) {
        case MidiFileLoopType.rpgMaker:
          if (data1 == 111) {
            return MidiMessage.loopStart();
          }
          break;

        case MidiFileLoopType.incredibleMachine:
          if (data1 == 110) {
            return MidiMessage.loopStart();
          }
          if (data1 == 111) {
            return MidiMessage.loopEnd();
          }
          break;

        case MidiFileLoopType.finalFantasy:
          if (data1 == 116) {
            return MidiMessage.loopStart();
          }
          if (data1 == 117) {
            return MidiMessage.loopEnd();
          }
          break;

        default:
      }
    }

    return MidiMessage._(channel, command, data1, data2);
  }

  factory MidiMessage.tempoChange(int tempo) {
    final command = tempo >> 16;
    final data1 = tempo >> 8;
    final data2 = tempo;
    return MidiMessage._(
        MidiMessageType.tempoChange.value, command, data1, data2);
  }

  factory MidiMessage.timeSignature(
      int numerator, int denominator, int b1, int b2) {
    return MidiMessage._(
        MidiMessageType.timeSignature.value, 0, numerator, denominator);
  }

  factory MidiMessage.loopStart() {
    return MidiMessage._(MidiMessageType.loopStart.value, 0, 0, 0);
  }

  factory MidiMessage.loopEnd() {
    return MidiMessage._(MidiMessageType.loopEnd.value, 0, 0, 0);
  }

  factory MidiMessage.endOfTrack() {
    return MidiMessage._(MidiMessageType.endOfTrack.value, 0, 0, 0);
  }

  @override
  String toString() {
    switch (type) {
      case MidiMessageType.tempoChange:
        return "Tempo: $tempo";
      case MidiMessageType.loopStart:
        return "LoopStart";
      case MidiMessageType.loopEnd:
        return "LoopEnd";
      case MidiMessageType.endOfTrack:
        return "EndOfTrack";
      case MidiMessageType.timeSignature:
        return "TimeSignature: $data1/$data2";
      default:
        break;
    }

    var c = 'COM' + command.toRadixString(16);
    switch (command) {
      case 0x80:
        c = 'NoteOff';
        break;
      case 0x90:
        c = 'NoteOn';
        break;
      case 0xB0:
        c = 'CC';
        break;
      case 0xC0:
        c = 'ProgramChange';
        break;
    }

    var d1 = c.toString();
    if (command == 0xB0) {
      switch (data1) {
        case 0x00:
          d1 = 'SetBank';
          break;
        case 0x07:
          d1 = 'Volume';
          break;
        case 0x0A:
          d1 = 'Pan';
          break;
        case 0x40:
          d1 = 'Sustain';
          break;
        case 0x43:
          d1 = 'Soft';
          break;
        case 0x5B:
          d1 = 'Release';
          break;
        case 0x5D:
          d1 = 'ChorusSend';
          break;
        case 0x78:
          d1 = 'AllSoundOff';
          break;
        case 0x79:
          d1 = 'ResetAllControllers';
          break;
        case 0x7B:
          d1 = 'AllNotesOff';
          break;
        default:
          d1 = 'CC' + data1.toRadixString(16);
          break;
      }
    }
    if (command == 0x80 || command == 0x90) {
      d1 = _getNoteName(data1);
    }

    return 'CH$channel $c $d1 $data2';
  }

  String _toHexString(int value) {
    return value.toRadixString(16).toUpperCase().padLeft(2, '0');
  }

  MidiMessageType get type {
    // Using normal if-else as MessageType is not an enum
    if (channel == MidiMessageType.tempoChange.value) {
      return MidiMessageType.tempoChange;
    } else if (channel == MidiMessageType.loopStart.value) {
      return MidiMessageType.loopStart;
    } else if (channel == MidiMessageType.loopEnd.value) {
      return MidiMessageType.loopEnd;
    } else if (channel == MidiMessageType.endOfTrack.value) {
      return MidiMessageType.endOfTrack;
    } else if (channel == MidiMessageType.timeSignature.value) {
      return MidiMessageType.timeSignature;
    } else {
      return MidiMessageType.normal;
    }
  }

  double get tempo => 60000000.0 / ((command << 16) | (data1 << 8) | data2);

  (int numerator, int denominator) get timeSignature => (data1, data2);

  String _getNoteName(int data1) {
    /*
    21 = A0
    24 = C1
    127 = G9
    */
    if (data1 < 21 || data1 > 127) {
      return 'Note $data1';
    }
    var notes = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
    var octave = (data1 / 12).floor() - 1;
    var note = notes[data1 % 12];
    return '$note$octave';
  }
}

enum MidiMessageType {
  normal(0),
  timeSignature(248),
  tempoChange(252),
  loopStart(253),
  loopEnd(254),
  endOfTrack(255);

  final int value;

  const MidiMessageType(this.value);
}
