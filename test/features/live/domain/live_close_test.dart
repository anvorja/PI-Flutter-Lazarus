import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('traduce los códigos de cierre del backend a causas', () {
    expect(liveCloseCauseFromCode(4001), LiveCloseCause.upstreamEnded);
    expect(liveCloseCauseFromCode(4002), LiveCloseCause.upstreamError);
    expect(liveCloseCauseFromCode(4003), LiveCloseCause.quotaExceeded);
    expect(liveCloseCauseFromCode(4004), LiveCloseCause.serverMisconfigured);
    expect(liveCloseCauseFromCode(1008), LiveCloseCause.protocolError);
    expect(liveCloseCauseFromCode(1006), LiveCloseCause.unknown);
    expect(liveCloseCauseFromCode(null), LiveCloseCause.unknown);
  });
}
