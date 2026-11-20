/// Off web there is no page to reload, so the store lives in memory for the
/// life of the process.
final Map<String, String> _memory = {};

String? readSessionValue(String key) => _memory[key];

void writeSessionValue(String key, String value) => _memory[key] = value;

void removeSessionValue(String key) => _memory.remove(key);
