const COMMANDS: &[&str] = &[
    "initialize",
    "register_listener",
    "remove_listener",
    "set_source",
    "play",
    "pause",
    "seek_to",
    "set_rate",
    "get_state",
    "dispose",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .ios_path("ios")
        .build();
}
