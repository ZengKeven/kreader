import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Paints narrow strips of the same laid-out page on a cylindrical fold.
/// Layout, hit testing and the text model are independent of this transition.
class CurlPage extends SingleChildRenderObjectWidget {
  final double progress;
  final int variant;
  const CurlPage({
    super.key,
    required this.progress,
    required this.variant,
    super.child,
  });
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _Curl(progress, variant);
  @override
  void updateRenderObject(BuildContext context, covariant _Curl render) {
    render.update(progress, variant);
  }
}

class _Curl extends RenderProxyBox {
  double t;
  int variant;
  _Curl(this.t, this.variant);
  void update(double n, int v) {
    if (t != n || variant != v) {
      t = n;
      variant = v;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext ctx, Offset o) {
    if (child == null) return;
    final a = t.abs().clamp(0, 1);
    if (a < .003 || size.width < 1) {
      super.paint(ctx, o);
      return;
    }
    final w = size.width, h = size.height, mirror = t < 0;
    final start = w * (1 - a),
        fold = math.max(1.0, w * a),
        angle =
            (variant == 0
                ? 1.35
                : variant == 1
                ? 2.15
                : 1.78) *
            math.sin(a * math.pi / 2);
    double x(double u) => u <= start
        ? u
        : start +
              fold *
                  math.sin(angle * (u - start) / fold) /
                  math.max(.001, angle);
    double lift(double u) {
      final f = ((u - start) / fold).clamp(0, 1);
      return (variant == 1
              ? -.095
              : variant == 2
              ? 0.065
              : -.035) *
          h *
          a *
          f *
          f;
    }

    void draw(double from, double to) {
      final left = mirror ? w - to : from;
      final right = mirror ? w - from : to;
      final x1 = mirror ? w - x(to) : x(from),
          x2 = mirror ? w - x(from) : x(to);
      final y = lift((from + to) / 2);
      final sx = (x2 - x1) / (right - left);
      if (sx.abs() < .002) return;
      final matrix = Matrix4.identity()
        ..setEntry(0, 0, sx)
        ..setEntry(0, 3, x1 - sx * left)
        ..setEntry(1, 1, 1 - y / h)
        ..setEntry(1, 3, y);
      ctx.pushTransform(needsCompositing, o, matrix, (context, off) {
        context.pushClipRect(
          needsCompositing,
          off,
          Rect.fromLTRB(left, 0, right + .35, h),
          (c, p) => c.paintChild(child!, p),
        );
      });
      if (from >= start) {
        final darkness =
            (.5 - .5 * math.cos((from - start) / fold * math.pi)) * .28 * a;
        ctx.canvas.drawRect(
          Rect.fromLTRB(
            o.dx + math.min(x1, x2),
            o.dy + y,
            o.dx + math.max(x1, x2),
            o.dy + h,
          ),
          Paint()..color = Colors.black.withValues(alpha: darkness),
        );
      }
    }

    if (start > 0) draw(0, start);
    for (int i = 0; i < 16; i++) {
      draw(start + fold * i / 16, start + fold * (i + 1) / 16);
    }
  }
}
