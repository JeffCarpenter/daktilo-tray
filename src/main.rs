#![windows_subsystem = "windows"]

use auto_launch::{AutoLaunch, AutoLaunchBuilder};
use daktilo_lib::{app::App, audio, embed::EmbeddedConfig};
use rdev::listen;
use rodio::{cpal::traits::HostTrait, DeviceTrait};
use serde::{Deserialize, Serialize};
use std::{path::Path, sync::mpsc};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tracing_subscriber::prelude::*;
use tray_icon::{
    menu::{CheckMenuItemBuilder, Menu, MenuEvent, MenuId, MenuItem, Submenu},
    TrayIconBuilder,
};

const ICON_ENABLED: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/assets/typewritter_icon_enabled.png"
));
const ICON_DISABLED: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/assets/typewritter_icon_disabled.png"
));

const APP_NAME: &str = "Daktilo Tray";
const AUTOSTART_SMOKE_ENV: &str = "DAKTILO_AUTOSTART_ONLY";

enum EventKind {
    KeyEvent(rdev::Event),
    ChangeConfig {
        preset_name: String,
        device_name: String,
    },
    Enabled(bool),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct State {
    enabled: bool,
    current_preset_name: String,
    current_device_name: String,
    #[serde(default)]
    run_on_login: bool,
}

fn main() {
    // Set up tracing
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    if std::env::var_os(AUTOSTART_SMOKE_ENV).is_some() {
        match run_autostart_probe() {
            Ok(_) => {
                tracing::info!(
                    "Autostart smoke mode set default preference; exiting without starting UI."
                );
                return;
            }
            Err(err) => {
                tracing::error!("Autostart smoke mode failed: {err}");
                std::process::exit(1);
            }
        }
    }

    let config = EmbeddedConfig::parse().unwrap();
    let presets = config.sound_presets;
    let devices = audio::get_devices().expect("Fail to get computer audio devices");
    let (tx, rx) = mpsc::channel();

    // App states
    let cache_path = directories::BaseDirs::new()
        .unwrap()
        .cache_dir()
        .join("daktilo_tray_cache.toml");
    let default_device_name = resolve_default_device_name();
    let (mut state, restored_from_cache) = load_state(&cache_path, &default_device_name);
    let autostart_defaults = AutostartDefaults::load();
    if let Some(note) = autostart_defaults.description() {
        tracing::debug!("Autostart metadata: {}", note);
    }
    if !restored_from_cache {
        state.run_on_login = autostart_defaults.default_enabled;
    }
    let autostart_controller = AutostartController::new(APP_NAME);
    let mut autostart_available = autostart_controller.is_available();
    if autostart_available {
        match autostart_controller.is_enabled() {
            Ok(enabled) => {
                if restored_from_cache {
                    state.run_on_login = enabled;
                } else if enabled != state.run_on_login {
                    if let Err(err) = autostart_controller.set_enabled(state.run_on_login) {
                        tracing::warn!("Failed to apply default autostart preference: {err}");
                        state.run_on_login = enabled;
                    }
                }
            }
            Err(err) => {
                tracing::warn!("Failed to query autostart state: {err}");
                autostart_available = false;
                state.run_on_login = false;
            }
        }
    } else {
        state.run_on_login = false;
    }
    tracing::debug!("{:?}", &state);

    // Spawn a thread to listen to key events
    let tx1 = tx.clone();
    std::thread::spawn(move || {
        listen(move |event| {
            tx1.send(EventKind::KeyEvent(event))
                .unwrap_or_else(|e| tracing::error!("could not send event {:?}", e));
        })
        .expect("could not listen events");
    });

    // Spawn a thread to play sound
    let presets_clone = presets.clone();
    let init_device_name = state.current_device_name.clone();
    let init_preset_name = state.current_preset_name.clone();
    let mut enabled = state.enabled;

    tracing::debug!("Current device: {}", state.current_device_name);
    std::thread::spawn(move || {
        let preset = presets_clone
            .iter()
            .find(|p| p.name == init_preset_name)
            .unwrap();
        let mut app = App::init(
            config.mute_key,
            preset.clone(),
            None,
            Some(init_device_name),
        )
        .unwrap();
        loop {
            match rx.recv() {
                Ok(EventKind::KeyEvent(event)) => {
                    if enabled {
                        app.handle_key_event(event.clone()).unwrap();
                    }
                }
                Ok(EventKind::ChangeConfig {
                    preset_name,
                    device_name,
                }) => {
                    let preset = presets_clone
                        .iter()
                        .find(|p| p.name == preset_name)
                        .unwrap();
                    app = App::init(
                        config.mute_key,
                        preset.clone(),
                        None,
                        Some(device_name.to_lowercase()),
                    )
                    .unwrap();
                }
                Ok(EventKind::Enabled(is_enabled)) => enabled = is_enabled,
                Err(e) => {
                    tracing::error!("{}", e);
                }
            }
        }
    });

    let enabled_icon = load_icon(ICON_ENABLED);
    let disabled_icon = load_icon(ICON_DISABLED);
    let presets_menu = Submenu::new("Presets", true);
    let devices_menu = Submenu::new("Devices", true);
    let enable_menu = MenuItem::new(if state.enabled { "Disable" } else { "Enable" }, true, None);
    let autostart_menu = if autostart_available {
        Some(
            CheckMenuItemBuilder::new()
                .id(MenuId(String::from("autostart_toggle")))
                .text(autostart_defaults.menu_label())
                .enabled(true)
                .checked(state.run_on_login)
                .build(),
        )
    } else {
        None
    };
    let exit_menu = MenuItem::new("Exit", true, None);
    let preset_items: Vec<_> = presets
        .iter()
        .enumerate()
        .map(|(i, p)| {
            CheckMenuItemBuilder::new()
                .id(MenuId(format!("preset_{i}")))
                .text(&p.name)
                .enabled(true)
                .checked(p.name == state.current_preset_name)
                .build()
        })
        .collect();
    for item in preset_items.iter() {
        presets_menu.append(item).unwrap();
    }
    let device_items: Vec<_> = devices
        .iter()
        .enumerate()
        .map(|(i, (name, _))| {
            CheckMenuItemBuilder::new()
                .id(MenuId(format!("device_{i}")))
                .text(name)
                .enabled(true)
                .checked(name.to_lowercase() == state.current_device_name)
                .build()
        })
        .collect();
    for item in device_items.iter() {
        devices_menu.append(item).unwrap();
    }
    let mut tray_icon = None;

    let menu_channel = MenuEvent::receiver();
    let event_loop = EventLoopBuilder::new().build();
    let tx2 = tx.clone();
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;

        if let tao::event::Event::NewEvents(tao::event::StartCause::Init) = event {
            // We create the icon once the event loop is actually running
            // to prevent issues like https://github.com/tauri-apps/tray-icon/issues/90
            // Creating tray icon
            let tray_menu = Menu::new();
            tray_menu
                .append_items(&[&presets_menu, &devices_menu, &enable_menu])
                .unwrap();
            if let Some(item) = autostart_menu.as_ref() {
                tray_menu.append(item).unwrap();
            }
            tray_menu.append(&exit_menu).unwrap();
            tray_icon = Some(
                TrayIconBuilder::new()
                    .with_menu(Box::new(tray_menu))
                    .with_icon(if state.enabled {
                        enabled_icon.clone()
                    } else {
                        disabled_icon.clone()
                    })
                    .with_tooltip("Daktilo Tray")
                    .build()
                    .unwrap(),
            );

            // We have to request a redraw here to have the icon actually show up.
            // Tao only exposes a redraw method on the Window so we use core-foundation directly.
            #[cfg(target_os = "macos")]
            unsafe {
                use core_foundation::runloop::{CFRunLoopGetMain, CFRunLoopWakeUp};

                let rl = CFRunLoopGetMain();
                CFRunLoopWakeUp(rl);
            }
        }

        if let Ok(event) = menu_channel.try_recv() {
            // Enable/disable app
            if event.id() == enable_menu.id() {
                if state.enabled {
                    state.enabled = false;
                    enable_menu.set_text("Enable");
                    tray_icon
                        .as_mut()
                        .unwrap()
                        .set_icon(Some(disabled_icon.clone()))
                        .unwrap();
                } else {
                    state.enabled = true;
                    enable_menu.set_text("Disable");
                    tray_icon
                        .as_mut()
                        .unwrap()
                        .set_icon(Some(enabled_icon.clone()))
                        .unwrap();
                }
                tx2.send(EventKind::Enabled(state.enabled)).unwrap();
            }
            // Exit app
            else if event.id() == exit_menu.id() {
                std::fs::write(&cache_path, toml::to_string(&state).unwrap()).unwrap();
                *control_flow = ControlFlow::ExitWithCode(0);
            } else if autostart_menu
                .as_ref()
                .map(|item| event.id() == item.id())
                .unwrap_or(false)
            {
                if let Some(item) = autostart_menu.as_ref() {
                    let desired = !state.run_on_login;
                    match autostart_controller.set_enabled(desired) {
                        Ok(_) => {
                            state.run_on_login = desired;
                            item.set_checked(desired);
                        }
                        Err(err) => {
                            tracing::error!("Failed to toggle run on login: {err}");
                            item.set_checked(state.run_on_login);
                        }
                    }
                }
            } else {
                let MenuId(id) = event.id();
                // Change preset
                if id.starts_with("preset_") {
                    let checked_i: usize = (id.strip_prefix("preset_").unwrap()).parse().unwrap();
                    preset_items.iter().enumerate().for_each(|(i, p)| {
                        if i == checked_i {
                            state.current_preset_name = p.text();
                            tx2.send(EventKind::ChangeConfig {
                                preset_name: state.current_preset_name.clone(),
                                device_name: state.current_device_name.clone(),
                            })
                            .unwrap();
                        }
                        p.set_checked(i == checked_i);
                    });
                }
                // Change audio device
                else if id.starts_with("device_") {
                    let checked_i: usize = (id.strip_prefix("device_").unwrap()).parse().unwrap();
                    device_items.iter().enumerate().for_each(|(i, d)| {
                        if i == checked_i {
                            state.current_device_name = d.text().to_lowercase();
                            tx2.send(EventKind::ChangeConfig {
                                preset_name: state.current_preset_name.clone(),
                                device_name: state.current_device_name.clone(),
                            })
                            .unwrap();
                        }
                        d.set_checked(i == checked_i)
                    });
                } else {
                    unreachable!();
                }
            }
            println!("{event:?}");
        }
    });
}

fn load_icon(bytes: &[u8]) -> tray_icon::Icon {
    let (icon_rgba, icon_width, icon_height) = {
        let image = image::load_from_memory(bytes)
            .expect("Failed to open icon path")
            .into_rgba8();
        let (width, height) = image.dimensions();
        let rgba = image.into_raw();
        (rgba, width, height)
    };
    tray_icon::Icon::from_rgba(icon_rgba, icon_width, icon_height).expect("Failed to open icon")
}

fn load_state(cache_path: &Path, fallback_device: &str) -> (State, bool) {
    if let Ok(content) = std::fs::read_to_string(cache_path) {
        if let Ok(mut cached_state) = toml::from_str::<State>(&content) {
            if !device_exists(&cached_state.current_device_name) {
                cached_state.current_device_name = fallback_device.to_string();
            }
            return (cached_state, true);
        }
    }
    (default_state(fallback_device), false)
}

fn default_state(default_device_name: &str) -> State {
    State {
        enabled: true,
        current_preset_name: String::from("default"),
        current_device_name: default_device_name.to_string(),
        run_on_login: false,
    }
}

fn run_autostart_probe() -> Result<(), String> {
    let defaults = AutostartDefaults::load();
    let desired = defaults.default_enabled;
    let controller = AutostartController::new(APP_NAME);
    if !controller.is_available() {
        return Err("Autostart is not supported on this platform".to_string());
    }
    controller
        .set_enabled(desired)
        .map_err(|err| format!("Failed to set autostart preference: {err}"))?;
    match controller.is_enabled() {
        Ok(state) if state == desired => {
            tracing::debug!("Autostart verified -> {}", desired);
            Ok(())
        }
        Ok(state) => Err(format!(
            "Autostart verification mismatch. Expected {desired}, observed {state}"
        )),
        Err(err) => Err(format!("Failed to verify autostart state: {err}")),
    }
}

fn resolve_default_device_name() -> String {
    rodio::cpal::default_host()
        .default_output_device()
        .and_then(|device| device.name().ok())
        .map(|name| name.to_lowercase())
        .unwrap_or_else(|| "default".to_string())
}

fn device_exists(device_name: &str) -> bool {
    rodio::cpal::default_host()
        .output_devices()
        .map(|mut devices| {
            devices.any(|device| {
                device
                    .name()
                    .map(|name| name.to_lowercase() == device_name)
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

#[derive(Debug, Clone)]
struct AutostartDefaults {
    default_enabled: bool,
    menu_label: String,
    tooltip: Option<String>,
}

impl AutostartDefaults {
    fn load() -> Self {
        const DIST_CONFIG: &str =
            include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/dist-workspace.toml"));
        toml::from_str::<DistWorkspace>(DIST_CONFIG)
            .ok()
            .and_then(|cfg| cfg.workspace)
            .and_then(|cfg| cfg.metadata)
            .and_then(|cfg| cfg.dist)
            .and_then(|cfg| cfg.autostart)
            .map(|cfg| Self {
                default_enabled: cfg.default_enabled.unwrap_or(false),
                menu_label: cfg
                    .menu_label
                    .unwrap_or_else(|| "Launch Daktilo Tray at login".to_string()),
                tooltip: cfg.tooltip,
            })
            .unwrap_or_default()
    }

    fn menu_label(&self) -> &str {
        &self.menu_label
    }

    fn description(&self) -> Option<&str> {
        self.tooltip.as_deref()
    }
}

impl Default for AutostartDefaults {
    fn default() -> Self {
        Self {
            default_enabled: false,
            menu_label: "Launch Daktilo Tray at login".to_string(),
            tooltip: None,
        }
    }
}

#[derive(Debug, Deserialize)]
struct DistWorkspace {
    workspace: Option<WorkspaceSection>,
}

#[derive(Debug, Deserialize)]
struct WorkspaceSection {
    metadata: Option<WorkspaceMetadata>,
}

#[derive(Debug, Deserialize)]
struct WorkspaceMetadata {
    dist: Option<DistSection>,
}

#[derive(Debug, Deserialize)]
struct DistSection {
    autostart: Option<DistAutostart>,
}

#[derive(Debug, Deserialize)]
struct DistAutostart {
    default_enabled: Option<bool>,
    menu_label: Option<String>,
    tooltip: Option<String>,
}

struct AutostartController {
    launcher: Option<AutoLaunch>,
}

impl AutostartController {
    fn new(app_name: &str) -> Self {
        if !AutoLaunch::is_support() {
            return Self { launcher: None };
        }
        let app_path = std::env::current_exe()
            .ok()
            .map(|path| path.to_string_lossy().into_owned());
        let launcher = app_path.and_then(|path| {
            let mut builder = AutoLaunchBuilder::new();
            builder.set_app_name(app_name);
            builder.set_app_path(&path);
            builder.build().ok()
        });
        Self { launcher }
    }

    fn is_available(&self) -> bool {
        self.launcher.is_some()
    }

    fn is_enabled(&self) -> Result<bool, auto_launch::Error> {
        self.launcher
            .as_ref()
            .map(|launcher| launcher.is_enabled())
            .unwrap_or(Ok(false))
    }

    fn set_enabled(&self, enable: bool) -> Result<(), auto_launch::Error> {
        if let Some(launcher) = self.launcher.as_ref() {
            if enable {
                launcher.enable()?;
            } else {
                launcher.disable()?;
            }
        }
        Ok(())
    }
}
