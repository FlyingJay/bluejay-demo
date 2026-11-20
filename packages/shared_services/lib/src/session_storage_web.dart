// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'session_storage_stub.dart' as memory;

// The tab's sessionStorage: it survives a reload and is cleared when the tab
// closes. A browser can refuse access (storage disabled, some private
// modes), so every call falls back to memory.

String? readSessionValue(String key) {
  try {
    return html.window.sessionStorage[key] ?? memory.readSessionValue(key);
  } catch (_) {
    return memory.readSessionValue(key);
  }
}

void writeSessionValue(String key, String value) {
  memory.writeSessionValue(key, value);
  try {
    html.window.sessionStorage[key] = value;
  } catch (_) {}
}

void removeSessionValue(String key) {
  memory.removeSessionValue(key);
  try {
    html.window.sessionStorage.remove(key);
  } catch (_) {}
}
