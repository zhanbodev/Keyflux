use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

const LIMIT: usize = 16 * 1024;
pub struct Core {
    pub binary: PathBuf,
    pub directory: Option<PathBuf>,
    pub simulated: bool,
    child: Mutex<Option<Child>>,
    gate: Mutex<()>,
}
impl Core {
    pub fn new(binary: PathBuf, directory: Option<PathBuf>, simulated: bool) -> Self {
        Self {
            binary,
            directory,
            simulated,
            child: Mutex::new(None),
            gate: Mutex::new(()),
        }
    }
    fn command(&self, args: &[&str]) -> Command {
        self.make_command(args, true)
    }
    fn make_command(&self, args: &[&str], scoped: bool) -> Command {
        let mut cmd = Command::new(&self.binary);
        cmd.args(args);
        if scoped {
            if let Some(dir) = &self.directory {
                cmd.arg("--state-dir").arg(dir);
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        cmd
    }
    // Only fixed, reviewed CLI operations can reach here. No shell, HID setters,
    // provider configuration installer or user-controlled executable arguments.
    pub fn call(&self, op: &str, input: Option<&Value>) -> Result<Value, String> {
        if ![
            "status",
            "theme-get",
            "theme-set",
            "validate-theme",
            "stop",
            "preview",
        ]
        .contains(&op)
        {
            return Err("UnsupportedOperation".into());
        }
        let args = if op == "preview" {
            vec!["preview", "thinking", "--signal-stdin"]
        } else {
            vec![op]
        };
        self.execute(&args, input, true)
    }
    pub fn probe_device(&self) -> Result<Value, String> {
        self.execute(&["hardware-probe"], None, false)
    }
    pub fn apply_device(&self, signal: &Value, identity: &str) -> Result<Value, String> {
        let object = signal.as_object().ok_or("InvalidSignal")?;
        let color = object
            .get("color")
            .and_then(Value::as_str)
            .ok_or("InvalidSignal")?;
        let brightness = object
            .get("brightness")
            .and_then(Value::as_u64)
            .ok_or("InvalidSignal")?;
        if object.len() != 2
            || color.len() != 7
            || !color.starts_with('#')
            || !color.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
            || brightness > 100
        {
            return Err("InvalidSignal".into());
        }
        self.execute(
            &[
                "hardware-solid",
                color,
                &brightness.to_string(),
                "--expect-device",
                identity,
            ],
            None,
            false,
        )
    }
    pub fn restore_device(&self, identity: &str) -> Result<Value, String> {
        self.execute(
            &["hardware-restore", "--expect-device", identity],
            None,
            false,
        )
    }
    fn execute(&self, args: &[&str], input: Option<&Value>, scoped: bool) -> Result<Value, String> {
        let bytes = input
            .map(serde_json::to_vec)
            .transpose()
            .map_err(|_| "InvalidTheme")?;
        if bytes.as_ref().is_some_and(|v| v.len() > LIMIT) {
            return Err("PayloadTooLarge".into());
        }
        let mut child = self
            .make_command(args, scoped)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| "CoreLaunchFailed")?;
        let mut stdin = child.stdin.take().ok_or("CoreStdinUnavailable")?;
        let writer = thread::spawn(move || {
            if let Some(bytes) = bytes {
                let _ = stdin.write_all(&bytes);
            }
        });
        let stdout = child.stdout.take().ok_or("CoreStdoutUnavailable")?;
        let stderr = child.stderr.take().ok_or("CoreStderrUnavailable")?;
        let reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.take(131073).read_to_end(&mut bytes);
            bytes
        });
        let errors = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.take(16385).read_to_end(&mut bytes);
            bytes
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        let _ = writer.join();
        let output = reader.join().map_err(|_| "CoreReadFailed")?;
        let _ = errors.join(); // Never expose stderr/user paths to the WebView.
        let status = status.ok_or("CoreTimeout")?;
        if output.len() > 131072 {
            return Err("CoreReplyTooLarge".into());
        }
        let value: Value = serde_json::from_slice(&output).map_err(|_| "InvalidCoreReply")?;
        if !status.success() || value.get("ok").and_then(Value::as_bool) == Some(false) {
            return Err(value
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("CoreOperationFailed")
                .to_owned());
        }
        Ok(value)
    }
    pub fn ensure(&self) -> Result<(), String> {
        let _gate = self.gate.lock().map_err(|_| "CoreLockFailed")?;
        if let Ok(value) = self.call("status", None) {
            if !self.simulated && value["result"]["backend"] == "simulated" {
                return Err("SimulationNotAllowed".into());
            }
            return Ok(());
        }
        let mut owner = self.child.lock().map_err(|_| "CoreLockFailed")?;
        if let Some(child) = owner.as_mut() {
            if child.try_wait().map_err(|_| "CoreWaitFailed")?.is_none() {
                return Err("CoreStarting".into());
            }
        }
        let mut args = vec!["serve"];
        if self.simulated {
            args.push("--simulate");
        }
        *owner = Some(
            self.command(&args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| "CoreLaunchFailed")?,
        );
        drop(owner);
        for _ in 0..30 {
            thread::sleep(Duration::from_millis(80));
            if self.call("status", None).is_ok() {
                return Ok(());
            }
        }
        Err("CoreStartupFailed".into())
    }
    pub fn owned(&self) -> bool {
        self.child.lock().map(|c| c.is_some()).unwrap_or(false)
    }
    pub fn stop_owned(&self) {
        let Ok(mut owner) = self.child.lock() else {
            return;
        };
        let Some(mut child) = owner.take() else {
            return;
        };
        drop(owner);
        if !matches!(child.try_wait(), Ok(None)) {
            return;
        }
        // Stop asks Zig to perform its own verified restoration before shutdown.
        // Never kill a core attached from another application/session.
        let _ = self.call("stop", None);
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if child.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(30));
        }
        // Never force-kill a potentially recovering device process.
    }
    pub fn context(&self) -> Value {
        use std::hash::{Hash, Hasher};
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        self.directory.hash(&mut hash);
        json!({"instance_id": format!("{:016x}", hash.finish()), "core_owned": self.owned(), "hardware_writes": false})
    }
}

pub fn bundled_binary(exe: &Path) -> PathBuf {
    exe.parent()
        .unwrap_or(Path::new("."))
        .join(if cfg!(windows) {
            "keyflux.exe"
        } else {
            "keyflux"
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hardware_signal_rejects_untrusted_fields_before_launch() {
        let core = Core::new(PathBuf::from("not-executed"), None, false);
        for signal in [
            json!({"color":"#ff00ff;sh","brightness":10}),
            json!({"color":"#FFFFFF","brightness":101}),
            json!({"color":"#FFFFFF","brightness":10,"zone":"side"}),
        ] {
            assert_eq!(
                core.apply_device(&signal, "identity").unwrap_err(),
                "InvalidSignal"
            );
        }
    }
    #[test]
    fn command_surface_rejects_hardware_and_arbitrary_paths() {
        let core = Core::new(PathBuf::from("not-executed"), None, false);
        for op in [
            "hardware-solid",
            "hardware-restore",
            "setup-codex",
            "sh",
            "../keyflux",
        ] {
            assert_eq!(core.call(op, None).unwrap_err(), "UnsupportedOperation");
        }
    }
    #[test]
    fn oversized_input_is_rejected_before_launch() {
        let core = Core::new(PathBuf::from("not-executed"), None, false);
        assert_eq!(
            core.call("validate-theme", Some(&json!({"name": "x".repeat(17000)})))
                .unwrap_err(),
            "PayloadTooLarge"
        );
    }
    #[test]
    fn instance_context_does_not_publish_paths() {
        let core = Core::new(
            PathBuf::from("secret/executable"),
            Some(PathBuf::from("private/user/state")),
            true,
        );
        let context = core.context().to_string();
        assert!(!context.contains("private"));
        assert!(!context.contains("secret"));
        assert!(!core.owned());
    }
    #[test]
    fn real_zig_roundtrip_and_ownership() {
        let Some(binary) = std::env::var_os("KEYFLUX_TEST_CORE") else {
            eprintln!("KEYFLUX_TEST_CORE not supplied; Zig roundtrip not exercised");
            return;
        };
        let base = if cfg!(target_os = "macos") {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        let temp = base.join(format!("kf-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&temp).unwrap();
        let owner = Core::new(PathBuf::from(&binary), Some(temp.clone()), true);
        struct Stop<'a>(&'a Core);
        impl Drop for Stop<'_> {
            fn drop(&mut self) {
                self.0.stop_owned();
            }
        }
        let stop = Stop(&owner);
        owner.ensure().unwrap();
        assert!(owner.owned());
        assert_eq!(
            owner.call("status", None).unwrap()["result"]["backend"],
            "simulated"
        );
        let mut theme = owner.call("theme-get", None).unwrap()["theme"].clone();
        theme["schema_version"] = json!(2);
        theme["name"] = json!("状态配色");
        theme["side"] =
            json!({"enabled": true, "mode": "independent", "signals": theme["signals"].clone()});
        theme["side"]["signals"]["thinking"]["color"] = json!("#123456");
        owner.call("validate-theme", Some(&theme)).unwrap();
        owner.call("theme-set", Some(&theme)).unwrap();
        assert_eq!(owner.call("theme-get", None).unwrap()["theme"], theme);
        let attached = Core::new(PathBuf::from(binary), Some(temp.clone()), true);
        attached.ensure().unwrap();
        assert!(!attached.owned());
        attached.stop_owned();
        assert!(owner.call("status", None).is_ok());
        let mut bad = theme.clone();
        bad["signals"]["thinking"]["brightness"] = json!(101);
        assert!(owner.call("theme-set", Some(&bad)).is_err());
        assert_eq!(owner.call("theme-get", None).unwrap()["theme"], theme);
        owner
            .call(
                "preview",
                Some(&json!({"color":"#123456", "brightness":10})),
            )
            .unwrap();
        drop(stop);
        assert!(owner.call("status", None).is_err());
        owner.ensure().unwrap();
        assert_eq!(owner.call("theme-get", None).unwrap()["theme"], theme);
        owner.stop_owned();
        std::fs::remove_dir_all(temp).unwrap();
    }
}
