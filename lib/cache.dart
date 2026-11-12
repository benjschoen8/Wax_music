/// Inserts into [map] and evicts the oldest entries beyond [max] (Dart maps
/// keep insertion order), so in-memory caches can't grow without limit.
void putBounded<K, V>(Map<K, V> map, K key, V value, {int max = 100}) {
  map.remove(key);
  map[key] = value;
  while (map.length > max) {
    map.remove(map.keys.first);
  }
}
