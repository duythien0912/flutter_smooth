import 'dart:collection';
import 'dart:developer';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:smooth/smooth.dart';
import 'package:smooth/src/service_locator.dart';
import 'package:smooth/src/time/typed_time.dart';

class ExtraEventDispatcher {
  final _pendingEventManager = _PendingPointerEventManager();

  void handleMainTreePointerEvent(PointerEvent e) =>
      _pendingEventManager.handleMainTreePointerEvent(e);

  // TODO just prototype, not final code
  // #5867
  void dispatch({required AdjustedFrameTimeStamp smoothFrameTimeStamp}) {
    final gestureBinding = GestureBinding.instance;

    // final diffDateTimeToPointerEventTimeStamp =
    //     SmoothHostApiWrapped.instance.diffDateTimeToPointerEventTimeStamp;
    // if (diffDateTimeToPointerEventTimeStamp == null) {
    //   // not finish initialization
    //   return;
    // }

    // final now = clock.now();
    // final nowTimeStampInPointerEventClock = Duration(
    //     microseconds:
    //         now.microsecondsSinceEpoch - diffDateTimeToPointerEventTimeStamp);

    // print(
    //     'diffDateTimeToPointerEventTimeStamp=$diffDateTimeToPointerEventTimeStamp');

    // print('hackDispatchExtraPointerEvents '
    //     'pointer=$pointer '
    //     'hitTest=${gestureBinding.hitTests[pointer]!}');

    // final pendingEvents = gestureBinding.readEnginePendingEventsAndClear();

    // in order to mimic classical case
    // details see #6066
    final pendingEventMaxTimeStamp = smoothFrameTimeStamp - kOneFrameAFTS;
    final pendingEvents =
        _pendingEventManager.read(maxTimeStamp: pendingEventMaxTimeStamp);

    // print(
    //     'pendingPacket.len=${pendingPacket.data.length} pendingPacket.data=${pendingPacket.data}');

    // // WARN: this fake event is VERY dummy! many fields are not filled in
    // // so a real consumer of pointer event may get VERY confused!
    // final event = PointerMoveEvent(
    //   pointer: pointer,
    //   position: Offset(_nextDummyPosition, _nextDummyPosition),
    // );
    // _nextDummyPosition = (_nextDummyPosition + 10) % 300;

    final interestPipelineOwners = ServiceLocator
        .instance.auxiliaryTreeRegistry.trees
        .map((tree) => tree.pipelineOwner)
        .toList();

    // NOTE only deal with those events that does *not* require a [hitTest]
    //      pointer *move* events are such kind.
    final interestEvents = pendingEvents.whereType<PointerMoveEvent>().toList();

    // https://github.com/fzyzcjy/yplusplus/issues/5867#issuecomment-1263053441
    for (final event in interestEvents) {
      // TODO this is WRONG, will cause duplicate event sending! #5875
      gestureBinding.handlePointerEvent(
        event,
        filter: (entry) {
          final target = entry.target;
          return target is RenderObject &&
              interestPipelineOwners.contains(target.owner);
        },
      );
    }
  }
}

class _PendingPointerEventManager {
  final _pendingEvents = Queue<PointerEvent>();

  void handleMainTreePointerEvent(PointerEvent mainTreePointerEvent) {
    // #6165
    _pendingEvents.removeWhere(
        (e) => _isRoughlySamePointerEvent(e, mainTreePointerEvent));
  }

  List<PointerEvent> read({required AdjustedFrameTimeStamp maxTimeStamp}) {
    final timeConverter = ServiceLocator.instance.timeConverter;
    final maxPointerEventTimeStamp =
        timeConverter.dateTimeToPointerEventTimeStamp(
            timeConverter.adjustedFrameTimeStampToDateTime(maxTimeStamp));
    if (maxPointerEventTimeStamp == null) {
      // not initialized
      return const [];
    }

    _fetchFromEngine(sanityCheckLastEventTimeStamp: maxPointerEventTimeStamp);

    final ans = <PointerEvent>[];
    while (_pendingEvents.isNotEmpty &&
        _pendingEvents.first.timeStampTyped < maxPointerEventTimeStamp) {
      ans.add(_pendingEvents.removeFirst());
    }

    Timeline.timeSync(
      'PendingPointerEventManager.dequeue',
      arguments: <String, Object?>{'ans': ans.toBriefString()},
      () => null,
    );
    // SimpleLog.instance.log(
    //     'PendingPointerEventManager dequeue (to downstream) ${ans.toBriefString()}');

    return ans;
  }

  void _fetchFromEngine(
      {required PointerEventTimeStamp sanityCheckLastEventTimeStamp}) {
    final gestureBinding = GestureBinding.instance;

    final enginePendingEvents =
        gestureBinding.readEnginePendingEventsAndClear();

    Timeline.timeSync(
      'PendingPointerEventManager.enqueue',
      arguments: <String, Object?>{
        'enginePendingEvents': enginePendingEvents.toBriefString()
      },
      () => null,
    );
    // SimpleLog.instance.log(
    //     'PendingPointerEventManager enqueue (from engine) ${enginePendingEvents.toBriefString()}');

    assert(() {
      // be very loose
      const kThreshold =
          PointerEventTimeStamp.unchecked(microseconds: 100 * 1000);

      final eventTimeStamp = enginePendingEvents.lastOrNull?.timeStampTyped;
      if (eventTimeStamp != null &&
          (eventTimeStamp - sanityCheckLastEventTimeStamp).abs() > kThreshold) {
        throw AssertionError(
            'sanityCheckPointerEventTime failed: eventTimeStamp=$eventTimeStamp sanityCheckLastEventTimeStamp=$sanityCheckLastEventTimeStamp');
      }
      return true;
    }());

    _pendingEvents.addAll(enginePendingEvents);

    assert(_isNonDecreasing(
        _pendingEvents.map((e) => e.timeStampTyped.inMicroseconds).toList()));
  }

  // #6165
  static bool _isRoughlySamePointerEvent(PointerEvent a, PointerEvent b) =>
      a.pointer == b.pointer &&
      a.timeStamp == b.timeStamp &&
      a.position == b.position;
}

bool _isNonDecreasing(List<int> values) {
  for (var i = 0; i < values.length - 1; ++i) {
    if (values[i] > values[i + 1]) return false;
  }
  return true;
}

extension on List<PointerEvent> {
  String toBriefString() => map((e) => e.toBriefString()).toList().toString();
}

extension on PointerEvent {
  String toBriefString() => 'PointerEvent('
      'timeStamp: $timeStamp, '
      'dateTime: ${ServiceLocator.instance.timeConverter.pointerEventTimeStampToDateTime(timeStampTyped)}, '
      'position: $position'
      ')';
}
