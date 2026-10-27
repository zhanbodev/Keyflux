// macOS uses alpha as a native template; Windows keeps the colored brand mark.
pub fn icon() -> tauri::image::Image<'static> {
    if cfg!(target_os = "macos") {
        return menu_bar_icon();
    }
    colored_icon()
}

fn rounded(x: f32, y: f32, left: f32, top: f32, width: f32, height: f32, radius: f32) -> bool {
    let cx = x.clamp(left + radius, left + width - radius);
    let cy = y.clamp(top + radius, top + height - radius);
    x >= left
        && x <= left + width
        && y >= top
        && y <= top + height
        && (x - cx).powi(2) + (y - cy).powi(2) <= radius * radius
}

fn menu_bar_icon() -> tauri::image::Image<'static> {
    // tray-icon normalizes height to 18pt on macOS. A tight 26:18 canvas
    // preserves a 25.5 × 16.5pt mark instead of shrinking a padded square.
    const SCALE: u32 = 4;
    let mut pixels = Vec::with_capacity((26 * 18 * SCALE * SCALE * 4) as usize);
    for row in 0..18 * SCALE {
        for column in 0..26 * SCALE {
            let x = (column as f32 + 0.5) / SCALE as f32;
            let y = (row as f32 + 0.5) / SCALE as f32;
            let outline = rounded(x, y, 0.25, 0.75, 25.5, 16.5, 2.2)
                && !rounded(x, y, 1.4, 1.9, 23.2, 14.2, 1.05);
            let mut filled = outline;
            for r in 0..4 {
                for c in 0..8 {
                    if r == 3 && (1..7).contains(&c) {
                        continue;
                    }
                    filled |= rounded(
                        x,
                        y,
                        2.3 + c as f32 * 2.75,
                        3.2 + r as f32 * 3.05,
                        2.05,
                        2.1,
                        0.35,
                    );
                }
            }
            filled |= rounded(x, y, 5.05, 12.35, 15.8, 2.1, 0.35);
            pixels.extend_from_slice(&[255, 255, 255, if filled { 255 } else { 0 }]);
        }
    }
    tauri::image::Image::new_owned(pixels, 26 * SCALE, 18 * SCALE)
}

fn colored_icon() -> tauri::image::Image<'static> {
    let mut pixels = Vec::with_capacity(44 * 44 * 4);
    let inside = |x: f32, y: f32, left: f32, top: f32, width: f32, height: f32, radius: f32| {
        let cx = x.clamp(left + radius, left + width - radius);
        let cy = y.clamp(top + radius, top + height - radius);
        x >= left
            && x <= left + width
            && y >= top
            && y <= top + height
            && (x - cx).powi(2) + (y - cy).powi(2) <= radius * radius
    };
    for row in 0..44 {
        for column in 0..44 {
            let x = (column as f32 + 0.5) / 2.0;
            let y = (row as f32 + 0.5) / 2.0;
            let mut color = if inside(x, y, 0.5, 4.0, 21.0, 14.0, 2.0) {
                [35, 46, 59, 255]
            } else {
                [0, 0, 0, 0]
            };
            for r in 0..3 {
                for c in 0..7 {
                    if r == 2 && (1..6).contains(&c) {
                        continue;
                    }
                    if inside(
                        x,
                        y,
                        2.0 + c as f32 * 2.65,
                        5.5 + r as f32 * 3.7,
                        2.1,
                        2.8,
                        0.45,
                    ) {
                        color = match (r, c) {
                            (0, 0) => [255, 204, 57, 255],
                            (1, 2) => [0, 212, 231, 255],
                            (1, 3) => [74, 156, 248, 255],
                            (1, 4) => [143, 78, 247, 255],
                            _ => [222, 229, 236, 255],
                        };
                    }
                }
            }
            if inside(x, y, 4.65, 12.9, 12.7, 2.8, 0.45) {
                color = [222, 229, 236, 255];
            }
            pixels.extend_from_slice(&color);
        }
    }
    tauri::image::Image::new_owned(pixels, 44, 44)
}
