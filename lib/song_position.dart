class SongPosition implements Comparable<SongPosition> {
  final int bar;
  final int beat;
  final int tick;

  const SongPosition(this.bar, this.beat, this.tick);

  @override
  int compareTo(SongPosition other) {
    if (bar != other.bar) {
      return bar - other.bar;
    }
    if (beat != other.beat) {
      return beat - other.beat;
    }
    return tick - other.tick;
  }

  @override
  bool operator ==(Object other) {
    return other is SongPosition && compareTo(other) == 0;
  }

  @override
  int get hashCode => bar.hashCode ^ beat.hashCode ^ tick.hashCode;

  @override
  String toString() => 'SongTime($bar, $beat, $tick)';

  bool operator >(SongPosition other) => compareTo(other) > 0;
  bool operator <(SongPosition other) => compareTo(other) < 0;
  bool operator >=(SongPosition other) => compareTo(other) >= 0;
  bool operator <=(SongPosition other) => compareTo(other) <= 0;
}
