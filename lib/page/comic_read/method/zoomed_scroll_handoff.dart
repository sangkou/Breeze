import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:zephyr/page/comic_read/widgets/layout/read_layout.dart';

/// 将放大条漫的纵向手势交给原列表，平移容器仅负责横向移动。
///
/// InteractiveViewer 的 child 是列表视口，而不是整章的高度。放大后列表
/// 虽然锁定了自身的拖动识别，仍可接收转交的拖动及松手速度。
class ZoomedScrollHandoff {
  double? _previousScale;
  Drag? _drag;
  ScrollPosition? _position;
  double _lastDeltaY = 0;

  bool get isActive => _drag != null || _position != null;

  void _onScrollActivityChanged() {
    if (_drag != null || _position?.isScrollingNotifier.value != false) {
      return;
    }
    _detachPosition();
  }

  void _detachPosition() {
    _position?.isScrollingNotifier.removeListener(_onScrollActivityChanged);
    _position = null;
  }

  void cancel() {
    final drag = _drag;
    final position = _position;
    // 拖动中的取消由 drag.cancel() 自己回弹；只有松手后的惯性需要定格，
    // 避免每次触摸都 jumpTo 产生多余的滚动通知。
    final stopMomentum =
        drag == null && (position?.isScrollingNotifier.value ?? false);
    _drag = null;
    _detachPosition();
    drag?.cancel();
    if (stopMomentum && position != null && position.hasPixels) {
      position.jumpTo(position.pixels);
    }
    _lastDeltaY = 0;
    _previousScale = null;
  }

  void end(ScaleEndDetails details) {
    final drag = _drag;
    _drag = null;
    if (drag == null) return;
    final scale = _previousScale ?? 1;
    final velocityY = details.velocity.pixelsPerSecond.dy;
    // 松手速度必须与最后一次拖动同向，否则视为误触不续惯性。
    final canFling = details.pointerCount == 0 && velocityY * _lastDeltaY > 0;
    final velocity = canFling ? velocityY / scale : 0.0;
    drag.end(
      DragEndDetails(
        velocity: Velocity(pixelsPerSecond: Offset(0, velocity)),
        primaryVelocity: velocity,
      ),
    );
    _onScrollActivityChanged();
  }

  void start(TransformationController transformation) {
    cancel();
    _previousScale = transformation.value.getMaxScaleOnAxis();
  }

  void update({
    required ScaleUpdateDetails details,
    required TransformationController transformation,
    required ScrollController scrollController,
    required bool enabled,
  }) {
    if (!enabled) {
      cancel();
      return;
    }

    final scale = transformation.value.getMaxScaleOnAxis();
    final previousScale = _previousScale;
    _previousScale = scale;

    // 捏合及缩放锚点变化不应改变列表位置。
    if (details.pointerCount != 1 ||
        previousScale == null ||
        (scale - previousScale).abs() > 0.0001 ||
        scale <= kScaleLockThreshold ||
        !scrollController.hasClients) {
      cancel();
      _previousScale = scale;
      return;
    }

    // 不先消耗视口再转交边界余量：整次纵向拖动使用同一列表物理，
    // 避免两套惯性、边界裁剪和重新起步造成速度突变。
    final deltaY = details.focalPointDelta.dy;
    if (deltaY.abs() < 0.001) return;
    final position = scrollController.position;
    if (_drag == null) {
      _detachPosition();
      _position = position;
      position.isScrollingNotifier.addListener(_onScrollActivityChanged);
      _drag = position.drag(
        DragStartDetails(globalPosition: details.focalPoint),
        () {
          // 正常松手时 end() 已先清空 _drag，继续跟踪松手后的惯性；
          // 只有异常取消才在这里解除跟踪。
          if (_drag != null) {
            _drag = null;
            _detachPosition();
          }
        },
      );
    }
    _lastDeltaY = deltaY;
    _drag!.update(
      DragUpdateDetails(
        globalPosition: details.focalPoint,
        delta: Offset(0, deltaY / scale),
        primaryDelta: deltaY / scale,
      ),
    );
  }
}
