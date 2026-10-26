fn main() {
    let manifest = tauri_build::AppManifest::new().commands(&[
        "get_status",
        "get_theme",
        "save_theme",
        "preview_main",
        "import_theme",
        "export_theme",
    ]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest))
        .expect("desktop build configuration");
}
