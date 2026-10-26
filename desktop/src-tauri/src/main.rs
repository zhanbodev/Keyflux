#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod core;
use core::Core;
use serde_json::Value;
use std::{fs, io::Read, path::PathBuf, sync::Arc};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager, State, WebviewUrl, WebviewWindowBuilder,
};
use tauri_plugin_dialog::DialogExt;

type Shared = Arc<Core>;
type Reply = Result<Value, String>;

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|_| "DesktopTaskFailed".to_owned())?
}
#[tauri::command]
async fn get_status(core: State<'_, Shared>) -> Reply {
    let core = core.inner().clone();
    blocking(move || {
        let mut value = match core.call("status", None) {
            Ok(value) => value,
            Err(_) => {
                core.ensure()?;
                core.call("status", None)?
            }
        };
        value["desktop"] = core.context();
        Ok(value)
    })
    .await
}
#[tauri::command]
async fn get_theme(core: State<'_, Shared>) -> Reply {
    let core = core.inner().clone();
    blocking(move || {
        core.ensure()?;
        core.call("theme-get", None)
    })
    .await
}
#[tauri::command]
async fn save_theme(core: State<'_, Shared>, theme: Value) -> Reply {
    let core = core.inner().clone();
    blocking(move || {
        core.ensure()?;
        core.call("validate-theme", Some(&theme))?;
        core.call("theme-set", Some(&theme))
    })
    .await
}
#[tauri::command]
async fn preview_main(core: State<'_, Shared>, signal: Value) -> Reply {
    let core = core.inner().clone();
    blocking(move || {
        core.ensure()?;
        if core.call("status", None)?["result"]["backend"] != "simulated" {
            return Err("SimulationRequired".into());
        }
        core.call("preview", Some(&signal))
    })
    .await
}
#[tauri::command]
async fn import_theme(
    app: tauri::AppHandle,
    core: State<'_, Shared>,
) -> Result<Option<Value>, String> {
    let core = core.inner().clone();
    blocking(move || {
        let Some(file) = app
            .dialog()
            .file()
            .add_filter("Keyflux theme", &["json"])
            .blocking_pick_file()
        else {
            return Ok(None);
        };
        let path = file.into_path().map_err(|_| "InvalidImportPath")?;
        let mut bytes = Vec::new();
        fs::File::open(path)
            .map_err(|_| "ThemeReadFailed")?
            .take(16385)
            .read_to_end(&mut bytes)
            .map_err(|_| "ThemeReadFailed")?;
        if bytes.len() > 16384 {
            return Err("PayloadTooLarge".into());
        }
        let theme: Value = serde_json::from_slice(&bytes).map_err(|_| "InvalidThemeJson")?;
        core.call("validate-theme", Some(&theme))?;
        Ok(Some(theme))
    })
    .await
}
#[tauri::command]
async fn export_theme(
    app: tauri::AppHandle,
    core: State<'_, Shared>,
    theme: Value,
) -> Result<bool, String> {
    let core = core.inner().clone();
    blocking(move || {
        core.call("validate-theme", Some(&theme))?;
        let Some(file) = app
            .dialog()
            .file()
            .add_filter("Keyflux theme", &["json"])
            .set_file_name("keyflux-theme.json")
            .blocking_save_file()
        else {
            return Ok(false);
        };
        let path = file.into_path().map_err(|_| "InvalidExportPath")?;
        let bytes = serde_json::to_vec_pretty(&theme).map_err(|_| "InvalidThemeJson")?;
        fs::write(path, bytes).map_err(|_| "ThemeWriteFailed")?;
        Ok(true)
    })
    .await
}
fn show_settings(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
    } else {
        let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
            .title("Keyflux")
            .inner_size(1120.0, 880.0)
            .min_inner_size(900.0, 680.0)
            .build();
    }
}
fn main() {
    let binary = if cfg!(debug_assertions) {
        std::env::var_os("KEYFLUX_CORE").map(PathBuf::from)
    } else {
        None
    }
    .unwrap_or_else(|| core::bundled_binary(&std::env::current_exe().expect("application path")));
    let directory = std::env::var_os("KEYFLUX_STATE_DIR").map(PathBuf::from);
    let service = Arc::new(Core::new(
        binary,
        directory,
        std::env::var_os("KEYFLUX_SIMULATE").is_some(),
    ));
    let exit_core = service.clone();
    tauri::Builder::default()
        .manage(service)
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_theme,
            save_theme,
            preview_main,
            import_theme,
            export_theme
        ])
        .setup(|app| {
            let settings = MenuItem::with_id(app, "settings", "设置…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Keyflux", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;
            let rgba: Vec<u8> = (0..22 * 22)
                .flat_map(|i| {
                    let x = i % 22;
                    let y = i / 22;
                    if (4..18).contains(&x) && ((y == 5 || y == 16) || (x == 4 || x == 17)) {
                        [30, 32, 35, 255]
                    } else {
                        [0, 0, 0, 0]
                    }
                })
                .collect();
            TrayIconBuilder::new()
                .icon(tauri::image::Image::new_owned(rgba, 22, 22))
                .icon_as_template(true)
                .tooltip("Keyflux — AI 状态灯")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "settings" => show_settings(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Keyflux desktop initialization")
        .run(move |_app, event| match event {
            tauri::RunEvent::ExitRequested {
                code: None, api, ..
            } => api.prevent_exit(),
            tauri::RunEvent::Exit => exit_core.stop_owned(),
            _ => {}
        });
}
