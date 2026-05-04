use crate::theme;
use std::f32::consts::PI;
use tauri::image::Image;
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};

const ICON_SIZE: u32 = 32;
const RADIUS: f32 = 12.0;
const STROKE: f32 = 3.0;

pub enum IconKind {
    NeedsConfig,
    AuthFailed,
    Error,
    Loading,
    Pct(f64),
}

pub fn render(kind: IconKind) -> Image<'static> {
    let mut pixmap = Pixmap::new(ICON_SIZE, ICON_SIZE).expect("pixmap alloc");
    let cx = ICON_SIZE as f32 / 2.0;
    let cy = ICON_SIZE as f32 / 2.0;

    let (color, draw_pct) = match kind {
        IconKind::NeedsConfig => (theme::color_idle(), 0.0),
        IconKind::AuthFailed => (theme::color_special_orange(), 100.0),
        IconKind::Error => (theme::color_special_red(), 100.0),
        IconKind::Loading => (theme::color_idle(), 0.0),
        IconKind::Pct(p) => (theme::color_for(p), p.max(0.0).min(100.0)),
    };

    // Background track (full circle, faint)
    let track_color = Color::from_rgba8(theme::TRACK.0, theme::TRACK.1, theme::TRACK.2, theme::TRACK.3);
    stroke_arc(&mut pixmap, cx, cy, RADIUS, 0.0, 360.0, STROKE, track_color);

    // Foreground arc (clockwise from top)
    if draw_pct > 0.0 {
        let sweep = (draw_pct as f32 / 100.0) * 360.0;
        stroke_arc(&mut pixmap, cx, cy, RADIUS, 0.0, sweep, STROKE, color);
    }

    let rgba = pixmap.take();
    Image::new_owned(rgba, ICON_SIZE, ICON_SIZE)
}

/// Stroke an arc starting at the top (12 o'clock), sweeping clockwise.
/// `start_deg` and `sweep_deg` are clockwise from 12 o'clock.
fn stroke_arc(pixmap: &mut Pixmap, cx: f32, cy: f32, r: f32, start_deg: f32, sweep_deg: f32, width: f32, color: Color) {
    if sweep_deg <= 0.0 {
        return;
    }
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;

    let mut pb = PathBuilder::new();
    let segments = 64.max((sweep_deg.abs() as i32) / 4);
    for i in 0..=segments {
        let t = i as f32 / segments as f32;
        let deg = start_deg + sweep_deg * t;
        // Map "clockwise from top" to standard math angle (counterclockwise from +x)
        let math = (-deg + 90.0).to_radians();
        let x = cx + r * math.cos();
        let y = cy - r * math.sin(); // y-down in pixmap, so subtract
        if i == 0 {
            pb.move_to(x, y);
        } else {
            pb.line_to(x, y);
        }
    }
    if let Some(path) = pb.finish() {
        let stroke = Stroke {
            width,
            line_cap: tiny_skia::LineCap::Round,
            ..Default::default()
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
        let _ = FillRule::EvenOdd;
        let _ = PI;
    }
}
