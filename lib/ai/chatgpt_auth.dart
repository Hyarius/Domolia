// Keep Android OAuth on native builds; exclude dart:io from Web.
// dart.library.js_interop covers JavaScript and WebAssembly targets.
export 'chatgpt_auth_io.dart'
    if (dart.library.js_interop) 'chatgpt_auth_web.dart';
