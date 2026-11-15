// Keep the existing Android OAuth flow intact, without importing dart:io
// into the browser's dependency graph.
export 'chatgpt_auth_web.dart'
    if (dart.library.io) 'chatgpt_auth_io.dart';
