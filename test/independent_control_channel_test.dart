import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio_method_channel.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 const channel=MethodChannel('mindbend_gemini_live_audio/methods');
 final binding=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
 tearDown(()=>binding.setMockMethodCallHandler(channel,null));
 test('cancel dispatch bypasses a parked push and native return is not drain',()async{
  final parked=Completer<void>(),entered=Completer<void>();
  binding.setMockMethodCallHandler(channel,(call)async{
   if(call.method=='pushPlaybackPcm'){entered.complete();await parked.future;return null;}
   if(call.method=='cancelFarewellDrain')return {'state':'cancelled','evidence':'none','restartBlocked':true,'teardown':'returned'};
   return null;
  });
  final port=MethodChannelMindbendGeminiLiveAudio();var dataReturned=false;
  final push=port.pushPlaybackPcm(Uint8List(8)).then((_)=>dataReturned=true);await entered.future;
  final ack=await port.cancelFarewellDrain();expect(dataReturned,false);expect(ack.teardown,'returned');expect(ack.isNativeDrain,false);parked.complete();await push;
 });
 test('failed native teardown remains failed and never a drain',()async{
  binding.setMockMethodCallHandler(channel,(call)async=>{'state':'cancelled','teardown':'failed','evidence':'none','restartBlocked':true});
  final ack=await MethodChannelMindbendGeminiLiveAudio().cancelFarewellDrain();expect(ack.teardown,'failed');expect(ack.isNativeDrain,false);
 });
 test('an older native plugin is explicitly unsupported',()async{
  binding.setMockMethodCallHandler(channel,(call)async=>throw MissingPluginException());
  await expectLater(MethodChannelMindbendGeminiLiveAudio().cancelFarewellDrain(),throwsA(isA<MissingPluginException>()));
 });
}
