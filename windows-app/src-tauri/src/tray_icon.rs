use crate::theme;
use tauri::image::Image;
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};

/// Render at 32x32 — Windows tray downscales to 16x16. Smaller source
/// downscales sharper than 64x64 → 16x16.
const ICON_SIZE: u32 = 32;
const RADIUS: f32 = 13.0;
const STROKE_W: f32 = 4.0;

pub enum IconKind {
    NeedsConfig,
    AuthFailed,
    Error,
    Loading,
    Pct(f64),
}

/// Tray icon: fully-opaque ring track + bright filled wedge that grows with %.
/// Plus a small solid dot at the center so the icon is always visible at 16x16.
pub fn render(kind: IconKind) -> Image<'static> {
    let mut pixmap = Pixmap::new(ICON_SIZE, ICON_SIZE).expect("pixmap alloc");
    let cx = ICON_SIZE as f32 / 2.0;
    let cy = ICON_SIZE as f32 / 2.0;

    let (color, draw_pct) = match kind {
        IconKind::NeedsConfig | IconKind::Loading => (theme::color_idle(), 0.0),
        IconKind::AuthFailed => (theme::color_special_orange(), 100.0),
        IconKind::Error => (theme::color_special_red(), 100.0),
        IconKind::Pct(p) => (theme::color_for(p), p.clamp(0.0, 100.0)),
    };

    // Always-visible track ring (opaque mid-gray) — gives the icon a clear silhouette.
    let track = Color::from_rgba8(180, 180, 180, 200);
    stroke_ring(&mut pixmap, cx, cy, RADIUS, STROKE_W, track);

    // Foreground wedge over the track
    if draw_pct > 0.0 {
        stroke_wedge(&mut pixmap, cx, cy, RADIUS, STROKE_W, draw_pct as f32, color);
    }

    // Solid orange center dot — visible at 16x16, makes the app distinct.
    fill_dot(&mut pixmap, cx, cy, 3.0, color);

    Image::new_owned(pixmap.take(), ICON_SIZE, ICON_SIZE)
}

fn stroke_ring(pixmap: &mut Pixmap, cx: f32, cy: f32, r: f32, width: f32, color: Color) {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    if let Some(path) = pb.finish() {
        let stroke = Stroke {
            width,
            ..Default::default()
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
    }
}

fn stroke_wedge(
    pixmap: &mut Pixmap,
    cx: f32,
    cy: f32,
    r: f32,
    width: f32,
    pct: f32,
    color: Color,
) {
    let sweep = (pct.min(100.0) / 100.0) * 360.0;
    if sweep <= 0.0 {
        return;
    }
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;

    let mut pb = PathBuilder::new();
    let segments = 64.max((sweep as i32) / 3);
    for i in 0..=segments {
        let t = i as f32 / segments as f32;
        let deg = sweep * t; // clockwise from top
        let math = (-deg + 90.0).to_radians();
        let x = cx + r * math.cos();
        let y = cy - r * math.sin();
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
    }
}

fn fill_dot(pixmap: &mut Pixmap, cx: f32, cy: f32, r: f32, color: Color) {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    if let Some(path) = pb.finish() {
        pixmap.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
    }
}
