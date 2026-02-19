use tauri::{
    plugin::{Builder, TauriPlugin},
    Runtime,
};

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "app.tauri.nativeaudio";

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_native_audio);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("native-audio")
        .setup(|_app, _api| {
            #[cfg(target_os = "android")]
            {
                let _ = _api.register_android_plugin(PLUGIN_IDENTIFIER, "NativeAudioPlugin")?;
            }
            #[cfg(target_os = "ios")]
            {
                let _ = _api.register_ios_plugin(init_plugin_native_audio)?;
            }
            Ok(())
        })
        .build()
}
