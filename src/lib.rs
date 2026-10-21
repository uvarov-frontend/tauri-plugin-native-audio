use tauri::{
    plugin::{Builder, TauriPlugin},
    Runtime,
};

#[cfg(desktop)]
mod desktop;
#[cfg(desktop)]
mod models;

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "app.tauri.nativeaudio";

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_native_audio);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    let mut builder = Builder::new("native-audio");

    #[cfg(desktop)]
    {
        builder = builder.invoke_handler(tauri::generate_handler![
            desktop::initialize,
            desktop::register_listener,
            desktop::remove_listener,
            desktop::set_source,
            desktop::play,
            desktop::pause,
            desktop::seek_to,
            desktop::set_rate,
            desktop::get_state,
            desktop::get_progress_checkpoint,
            desktop::clear_progress_checkpoint,
            desktop::dispose,
        ]);
    }

    builder
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
