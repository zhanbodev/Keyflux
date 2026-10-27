#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod codex;
mod core;
mod device;
mod tray;
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
type SharedDevice = Arc<device::Device>;
type SharedSource = Arc<codex::Source>;
type Reply = Result<Value, String>;

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|_| "DesktopTaskFailed".to_owned())?
}
#[tauri::command]
async fn get_status(core: State<'_, Shared>, source: State<'_, SharedSource>) -> Reply {
    let core = core.inner().clone();
    let source = source.inner().clone();
    blocking(move || {
        let mut value = match core.call("status", None) {
            Ok(value) => value,
            Err(_) => {
                core.ensure()?;
                core.call("status", None)?
            }
        };
        value["desktop"] = core.context();
        value["desktop"]["source"] = source.snapshot();
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
async fn save_theme(
    core: State<'_, Shared>,
    device: State<'_, SharedDevice>,
    theme: Value,
) -> Reply {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || {
        device.require_connected()?;
        core.ensure()?;
        core.call("validate-theme", Some(&theme))?;
        core.call("theme-set", Some(&theme))
    })
    .await
}
#[tauri::command]
async fn get_device(core: State<'_, Shared>, device: State<'_, SharedDevice>) -> Reply {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || device.status(core.as_ref())).await
}
#[tauri::command]
async fn connect_device(core: State<'_, Shared>, device: State<'_, SharedDevice>) -> Reply {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || {
        core.ensure()?;
        device.connect(&core)?;
        device.start_following(core.as_ref())
    })
    .await
}
#[tauri::command]
async fn disconnect_device(core: State<'_, Shared>, device: State<'_, SharedDevice>) -> Reply {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || device.disconnect(core.as_ref())).await
}
#[tauri::command]
async fn import_theme(
    app: tauri::AppHandle,
    core: State<'_, Shared>,
    device: State<'_, SharedDevice>,
) -> Result<Option<Value>, String> {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || {
        device.require_connected()?;
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
    device: State<'_, SharedDevice>,
    theme: Value,
) -> Result<bool, String> {
    let core = core.inner().clone();
    let device = device.inner().clone();
    blocking(move || {
        device.require_connected()?;
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
            .inner_size(1120.0, 780.0)
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
    let keyboard = Arc::new(device::Device::default());
    let exit_keyboard = keyboard.clone();
    let follow_core = service.clone();
    let follow_keyboard = keyboard.clone();
    let source = Arc::new(codex::Source::default());
    let source_core = service.clone();
    let source_keyboard = keyboard.clone();
    let follow_source = source.clone();
    tauri::Builder::default()
        .manage(service)
        .manage(keyboard)
        .manage(source)
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_theme,
            save_theme,
            get_device,
            connect_device,
            disconnect_device,
            import_theme,
            export_theme
        ])
        .setup(|app| {
            let settings = MenuItem::with_id(app, "settings", "设置…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Keyflux", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;
            TrayIconBuilder::new()
                .icon(tray::icon())
                .icon_as_template(cfg!(target_os = "macos"))
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
            tauri::RunEvent::Ready => {
                let source = follow_source.clone();
                let core = source_core.clone();
                let keyboard = source_keyboard.clone();
                std::thread::spawn(move || {
                    while !keyboard.closing() {
                        source.poll(&core);
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                });
                let core = follow_core.clone();
                let keyboard = follow_keyboard.clone();
                std::thread::spawn(move || {
                    while !keyboard.closing() {
                        keyboard.follow_core(&core);
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                });
            }
            tauri::RunEvent::ExitRequested {
                code: None, api, ..
            } => api.prevent_exit(),
            tauri::RunEvent::Exit => {
                let _ = exit_keyboard.shutdown(exit_core.as_ref());
                exit_core.stop_owned();
            }
            _ => {}
        });
}
