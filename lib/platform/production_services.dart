// Single platform composition point for the existing Domolia application.
// Native services remain the Android production implementation.
export 'production_services_web.dart'
    if (dart.library.io) 'production_services_io.dart';
