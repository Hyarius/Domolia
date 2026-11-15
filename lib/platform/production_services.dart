// One app, with native services unless compiling for a browser.
// Use js_interop for both JavaScript and WebAssembly Flutter builds.
export 'production_services_io.dart'
    if (dart.library.js_interop) 'production_services_web.dart';
