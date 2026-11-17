import 'package:domolia/illustration/image_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('App defaults and Party overrides persist separately', () async {
    final prefs=ImagePreferences();
    await prefs.initialize();
    expect((await prefs.forSession('s1')).count,1);
    const saved=ImageGenerationOptions(
        profileId:'ou', directorProfileId:'gpt',
        model:'visual',style:'dessin à l’encre');
    await prefs.saveApplication(saved);
    await prefs.saveParty('s1', saved.copyWith(model:'gpt-image-2'));
    final restarted=ImagePreferences();
    await restarted.initialize();
    expect((await restarted.forSession('s1')).model,'gpt-image-2');
    expect((await restarted.forSession('s2')).model,'visual');
    await restarted.saveParty('s1', null);
    expect((await restarted.forSession('s1')).model,'visual');
    prefs.dispose();
    restarted.dispose();
  });

  test('Invalid counts and negative spending cap are rejected', () {
    expect(()=>const ImageGenerationOptions(count:0).validate(),
        throwsFormatException);
    expect(()=>const ImageGenerationOptions(
      maximumCostUsd:-1).validate(),throwsFormatException);
  });
}
