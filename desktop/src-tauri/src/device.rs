use crate::core::Core;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Mutex;

// A narrow transport seam allows lifecycle tests without sending HID reports.
pub trait Hardware {
    fn inspect(&self) -> Result<Value, String>;
    fn apply(&self, signal: &Value, identity: &str) -> Result<Value, String>;
    fn restore(&self, identity: &str) -> Result<Value, String>;
}
impl Hardware for Core {
    fn inspect(&self) -> Result<Value, String> {
        self.inspect_device()
    }
    fn apply(&self, signal: &Value, identity: &str) -> Result<Value, String> {
        self.apply_device(signal, identity)
    }
    fn restore(&self, identity: &str) -> Result<Value, String> {
        self.restore_device(identity)
    }
}
#[derive(Default, Deserialize, Serialize)]
struct Recovery {
    required: bool,
    pending: bool,
    compatible: bool,
    code: Option<String>,
}
#[derive(Deserialize)]
struct Snapshot {
    probe: Option<Value>,
    recovery: Recovery,
    device_error: Option<String>,
}
#[derive(Default)]
struct Session {
    probe: Option<Value>,
    recovery: Recovery,
    restore_owned: bool,
    identity: Option<String>,
    closing: bool,
    last_error: Option<String>,
    following: bool,
    follow_error: Option<String>,
    last_signal: Option<Value>,
}
#[derive(Default)]
pub struct Device {
    session: Mutex<Session>,
}
fn bytes(value: &Value, count: usize) -> bool {
    value.as_array().is_some_and(|items| {
        items.len() == count && items.iter().all(|v| v.as_u64().is_some_and(|n| n <= 255))
    })
}
fn valid_probe(probe: &Value) -> bool {
    probe["schema_version"] == 1
        && probe["model_id"] == "nuphy-kick75-io"
        && probe["fingerprint"]
            .as_str()
            .is_some_and(|id| id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit()))
        && bytes(&probe["state"], 17)
        && probe["state"][1].as_u64().is_some_and(|v| v <= 100)
        && bytes(&probe["firmware"], 8)
        && bytes(&probe["geometry"], 8)
        && matches!(probe["profile"].as_u64(), Some(0 | 1))
}
fn writable(probe: &Value) -> bool {
    cfg!(target_os = "macos")
        && valid_probe(probe)
        && probe["profile"] == 0
        && probe["led_count"] == 85
        && probe["input_bytes"] == 64
        && probe["output_bytes"] == 64
        && probe["firmware"].as_array().is_some_and(|v| {
            v[..6]
                == [
                    json!(18),
                    json!(0),
                    json!(4),
                    json!(170),
                    json!(6),
                    json!(0),
                ]
        })
        && probe["geometry"]
            .as_array()
            .is_some_and(|v| v[..5] == [json!(0), json!(8), json!(4), json!(6), json!(15)])
}
fn readback(probe: &Value) -> Value {
    let state = &probe["state"];
    let solid = state[0] == 3 && state[4] == 0;
    json!({
        "mode": if solid {"solid"} else if state[0] == 0 {"custom"} else {"effect"},
        "mode_id": state[0], "brightness": state[1],
        "color": if solid {Some(format!("#{:02X}{:02X}{:02X}", state[6].as_u64().unwrap(), state[7].as_u64().unwrap(), state[8].as_u64().unwrap()))} else {None}
    })
}
fn public(session: &Session) -> Value {
    let recovery = &session.recovery;
    let mut result = json!({
        "connected": session.probe.is_some(), "writable": false,
        "reconnecting": false,
        "recovery_pending": recovery.required,
        "recovery_required": recovery.required && (recovery.pending || !recovery.compatible || !session.restore_owned),
        "can_restore": false,
        "last_error": session.follow_error.as_ref().or(session.last_error.as_ref()).or(recovery.code.as_ref()),
    });
    if let Some(probe) = &session.probe {
        let f = &probe["firmware"];
        result["writable"] = json!(writable(probe));
        result["native_main_effects"] = if writable(probe) {
            json!(["solid", "marquee", "orbit", "blink"])
        } else {
            json!([])
        };
        result["can_restore"] = json!(writable(probe) && recovery.required && recovery.compatible);
        result["model_id"] = probe["model_id"].clone();
        result["firmware"] = json!(format!(
            "{}.{}.{}.{}",
            f[2],
            f[1],
            f[0],
            f[4].as_u64().unwrap() | (f[5].as_u64().unwrap() << 8)
        ));
        result["profile"] = json!(if probe["profile"] == 0 { "Mac" } else { "Win" });
        result["state"] = probe["state"].clone();
        result["main"] = readback(probe);
    }
    result
}
fn refresh(session: &mut Session, hardware: &impl Hardware) -> Result<(), String> {
    // Mark an old reading unavailable before IO: no stale success on an error.
    session.probe = None;
    let result = (|| {
        let snapshot: Snapshot =
            serde_json::from_value(hardware.inspect()?).map_err(|_| "InvalidDeviceReply")?;
        session.recovery = snapshot.recovery;
        let probe = snapshot.probe.ok_or_else(|| {
            snapshot
                .device_error
                .unwrap_or_else(|| "DeviceNotFound".into())
        })?;
        if !valid_probe(&probe) {
            return Err("InvalidDeviceReply".into());
        }
        let identity = probe["fingerprint"].as_str().ok_or("InvalidDeviceReply")?;
        if session
            .identity
            .as_deref()
            .is_some_and(|old| old != identity)
        {
            return Err("DeviceChanged".into());
        }
        session.identity = Some(identity.to_owned());
        session.probe = Some(probe);
        Ok(())
    })();
    session.last_error = result.as_ref().err().cloned();
    result
}
fn restore_locked(session: &mut Session, hardware: &impl Hardware) -> Result<Value, String> {
    let probe = session.probe.as_ref().ok_or("NotConnected")?;
    if !writable(probe) {
        return Err("UnverifiedDevice".into());
    }
    if session.recovery.required && !session.recovery.compatible {
        return Err(session
            .recovery
            .code
            .clone()
            .unwrap_or_else(|| "RecoveryIdentityMismatch".into()));
    }
    let identity = session.identity.as_deref().ok_or("InvalidDeviceIdentity")?;
    let result = match hardware.restore(identity) {
        Ok(result) => result,
        Err(error) => {
            let _ = refresh(session, hardware);
            return Err(error);
        }
    };
    if let Some(state) = result.get("state") {
        if !bytes(state, 17) {
            return Err("InvalidDeviceReply".into());
        }
        session.probe.as_mut().ok_or("NotConnected")?["state"] = state.clone();
    }
    session.recovery = Recovery::default();
    session.restore_owned = false;
    session.last_error = None;
    let mut reply = public(session);
    reply["restored"] = result["restored"].clone();
    Ok(reply)
}
fn apply_locked(
    session: &mut Session,
    hardware: &impl Hardware,
    model: &str,
    signal: &Value,
) -> Result<Value, String> {
    if session.closing {
        return Err("AppClosing".into());
    }
    let probe = session.probe.as_ref().ok_or("NotConnected")?;
    if !writable(probe) {
        return Err("UnverifiedDevice".into());
    }
    if probe["model_id"].as_str() != Some(model) {
        return Err("DeviceChanged".into());
    }
    // A prior capture must be repaired before enabling writes in this session.
    if session.recovery.required
        && (session.recovery.pending || !session.recovery.compatible || !session.restore_owned)
    {
        return Err("RecoveryRequired".into());
    }
    let identity = session.identity.as_deref().ok_or("InvalidDeviceIdentity")?;
    let result = match hardware.apply(signal, identity) {
        Ok(result) => result,
        Err(error) => {
            let _ = refresh(session, hardware);
            return Err(error);
        }
    };
    if !bytes(&result["state"], 17) {
        return Err("InvalidDeviceReply".into());
    }
    if result["changed"] == true {
        session.restore_owned = true;
        session.recovery = Recovery {
            required: true,
            compatible: true,
            ..Recovery::default()
        };
    }
    session.probe.as_mut().ok_or("NotConnected")?["state"] = result["state"].clone();
    session.last_error = None;
    Ok(public(session))
}
impl Device {
    pub fn start_following(&self, core: &impl Hardware) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        if session.probe.is_none() {
            return Err("NotConnected".into());
        }
        // Explicit Connect claims control after repairing any matching capture.
        if session.recovery.required {
            restore_locked(&mut session, core)?;
        }
        session.following = true;
        session.follow_error = None;
        session.last_signal = None;
        Ok(public(&session))
    }
    pub fn follow_core(&self, core: &Core) {
        let active = self
            .session
            .lock()
            .is_ok_and(|s| s.following && s.probe.as_ref().is_some_and(writable) && !s.closing);
        if !active {
            return;
        }
        let status = core.call("status", None);
        let _ = self.follow_status(core, status.as_ref().ok());
    }
    fn follow_status(
        &self,
        hardware: &impl Hardware,
        status: Option<&Value>,
    ) -> Result<(), String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing || !session.following || session.probe.is_none() {
            return Ok(());
        }
        let result: Result<(), String> = (|| {
            let signal = match status {
                Some(status) if status["result"]["backend"] == "read-only" => {
                    let phase = status["result"]["state"]["phase"]
                        .as_str()
                        .ok_or("InvalidAgentStatus")?;
                    match phase {
                        "idle" | "unknown" => None,
                        "working" | "thinking" | "output" | "tool" | "attention" | "complete"
                        | "error" | "checking" | "verified" | "check_failed" => {
                            let signal = status["result"]
                                .get("lighting")
                                .filter(|s| !s.is_null())
                                .ok_or("InvalidAgentStatus")?;
                            let mut intent = signal.clone();
                            if let Some(action) =
                                status["result"].get("action").filter(|a| !a.is_null())
                            {
                                intent["effect"] = action["effect"].clone();
                                intent["speed"] = action["speed"].clone();
                            }
                            Some(intent)
                        }
                        _ => return Err("InvalidAgentStatus".into()),
                    }
                }
                Some(_) => return Err("SimulationNotAllowed".into()),
                None => None,
            };
            if signal == session.last_signal {
                return Ok(());
            }
            if let Some(signal) = &signal {
                apply_locked(&mut session, hardware, "nuphy-kick75-io", signal)?;
            } else if session.restore_owned {
                restore_locked(&mut session, hardware)?;
            }
            session.last_signal = signal;
            Ok(())
        })();
        if let Err(error) = &result {
            session.following = false; // Never retry ambiguous writes unattended.
            session.follow_error = Some(error.clone());
            if session.restore_owned
                && matches!(
                    error.as_str(),
                    "InvalidAgentStatus" | "SimulationNotAllowed" | "InvalidSignal"
                )
            {
                // An invalid source is unavailable, not a reason to leave an
                // earlier active-phase color on the device indefinitely.
                if let Err(recovery_error) = restore_locked(&mut session, hardware) {
                    session.follow_error = Some(recovery_error);
                }
                session.last_signal = None;
            }
        }
        result
    }
    pub fn closing(&self) -> bool {
        self.session.lock().map(|s| s.closing).unwrap_or(true)
    }
    pub fn require_connected(&self) -> Result<(), String> {
        let session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        if session.probe.is_none() {
            return Err("NotConnected".into());
        }
        Ok(())
    }
    pub fn connect(&self, core: &Core) -> Result<Value, String> {
        if core.simulated {
            return Err("SimulationNotAllowed".into());
        }
        self.connect_hardware(core)
    }
    fn connect_hardware(&self, hardware: &impl Hardware) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        // A new identity can only be selected by this explicit user action,
        // and only when this App owns no capture that must first be restored.
        if session.probe.is_none() && !session.restore_owned && !session.recovery.required {
            session.identity = None;
        }
        refresh(&mut session, hardware)?;
        Ok(public(&session))
    }
    pub fn status(&self, hardware: &impl Hardware) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.probe.is_some() && !session.closing {
            // Observe a user-connected session only. A lost connection stays
            // locked until an explicit Connect; polling never reopens it.
            let _ = refresh(&mut session, hardware);
        }
        Ok(public(&session))
    }
    #[cfg(test)]
    pub fn apply(
        &self,
        hardware: &impl Hardware,
        model: &str,
        signal: &Value,
    ) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        apply_locked(&mut session, hardware, model, signal)
    }

    #[cfg(test)]
    pub fn restore(&self, hardware: &impl Hardware) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        restore_locked(&mut session, hardware)
    }
    pub fn disconnect(&self, hardware: &impl Hardware) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        // Keep the same lock through restore and disconnect; an in-flight apply
        // cannot slip in between restoration and releasing the session.
        if session.restore_owned {
            restore_locked(&mut session, hardware)?;
        }
        *session = Session::default();
        Ok(public(&session))
    }
    pub fn shutdown(&self, hardware: &impl Hardware) -> Result<(), String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        session.closing = true;
        if session.restore_owned {
            restore_locked(&mut session, hardware)?;
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fake {
        snapshot: Mutex<Value>,
        calls: Mutex<Vec<String>>,
        ambiguous: bool,
    }
    fn probe() -> Value {
        json!({"schema_version":1,"model_id":"nuphy-kick75-io","fingerprint":"a".repeat(64),"profile":0,"led_count":85,"input_bytes":64,"output_bytes":64,"firmware":[18,0,4,170,6,0,247,247],"geometry":[0,8,4,6,15,130,247,247],"state":[2,60,2,0,1,0,153,153,153,0,60,2,1,0,255,0,0]})
    }
    impl Default for Fake {
        fn default() -> Self {
            Self {
                snapshot: Mutex::new(
                    json!({"probe":probe(),"recovery":{"required":false,"pending":false,"compatible":false,"code":null},"device_error":null}),
                ),
                calls: Mutex::default(),
                ambiguous: false,
            }
        }
    }
    impl Hardware for Fake {
        fn inspect(&self) -> Result<Value, String> {
            self.calls.lock().unwrap().push("inspect".into());
            Ok(self.snapshot.lock().unwrap().clone())
        }
        fn apply(&self, _signal: &Value, identity: &str) -> Result<Value, String> {
            assert_eq!(identity, "a".repeat(64));
            self.calls.lock().unwrap().push("apply".into());
            let mut snapshot = self.snapshot.lock().unwrap();
            snapshot["recovery"] =
                json!({"required":true,"pending":self.ambiguous,"compatible":true,"code":null});
            if self.ambiguous {
                snapshot["probe"] = Value::Null;
                snapshot["device_error"] = json!("DeviceDisconnected");
                return Err("DeviceDisconnected".into());
            }
            let state = json!([3, 15, 2, 0, 0, 0, 24, 199, 170, 0, 60, 2, 1, 0, 255, 0, 0]);
            snapshot["probe"]["state"] = state.clone();
            Ok(json!({"changed":true,"state":state}))
        }
        fn restore(&self, identity: &str) -> Result<Value, String> {
            assert_eq!(identity, "a".repeat(64));
            self.calls.lock().unwrap().push("restore".into());
            let mut snapshot = self.snapshot.lock().unwrap();
            snapshot["probe"] = probe();
            snapshot["recovery"] =
                json!({"required":false,"pending":false,"compatible":false,"code":null});
            Ok(json!({"restored":true,"state":probe()["state"]}))
        }
    }
    fn agent_status(phase: &str, color: &str) -> Value {
        json!({"result":{"backend":"read-only","state":{"phase":phase},"lighting":{"color":color,"brightness":15}}})
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn effect_and_speed_changes_write_once_and_unchanged_polls_do_not_animate_on_host() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        device.start_following(&hardware).unwrap();
        let mut status = agent_status("checking", "#6366F1");
        status["result"]["action"] = json!({"effect":"orbit","speed":2});
        device.follow_status(&hardware, Some(&status)).unwrap();
        device.follow_status(&hardware, Some(&status)).unwrap();
        status["result"]["action"]["speed"] = json!(4);
        device.follow_status(&hardware, Some(&status)).unwrap();
        status["result"]["action"]["effect"] = json!("blink");
        device.follow_status(&hardware, Some(&status)).unwrap();
        device.follow_status(&hardware, Some(&status)).unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "apply")
                .count(),
            3
        );
        device.follow_status(&hardware, None).unwrap();
        assert!(hardware.calls.lock().unwrap().contains(&"restore".into()));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn default_follow_deduplicates_signals_and_restores_on_idle_and_source_loss() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        device.start_following(&hardware).unwrap();
        let thinking = agent_status("thinking", "#06B6D4");
        device.follow_status(&hardware, Some(&thinking)).unwrap();
        device.follow_status(&hardware, Some(&thinking)).unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "apply")
                .count(),
            1
        );
        // Saving a changed palette changes the core-resolved signal, even if
        // the active phase stays the same. Repeated polls still write once.
        device
            .follow_status(&hardware, Some(&agent_status("thinking", "#18C7AA")))
            .unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "apply")
                .count(),
            2
        );
        device
            .follow_status(&hardware, Some(&agent_status("idle", "#000000")))
            .unwrap();
        device
            .follow_status(&hardware, Some(&agent_status("idle", "#000000")))
            .unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "restore")
                .count(),
            1
        );
        device
            .follow_status(&hardware, Some(&agent_status("output", "#8B5CF6")))
            .unwrap();
        device.follow_status(&hardware, None).unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "restore")
                .count(),
            2
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn follow_repairs_previous_capture_but_never_retries_an_ambiguous_write() {
        let hardware = Fake {
            ambiguous: true,
            ..Fake::default()
        };
        hardware.snapshot.lock().unwrap()["recovery"] =
            json!({"required":true,"pending":true,"compatible":true,"code":null});
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        device.start_following(&hardware).unwrap();
        assert_eq!(hardware.calls.lock().unwrap().last().unwrap(), "restore");
        let status = agent_status("working", "#3B82F6");
        assert_eq!(
            device.follow_status(&hardware, Some(&status)).unwrap_err(),
            "DeviceDisconnected"
        );
        device.follow_status(&hardware, Some(&status)).unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "apply")
                .count(),
            1
        );
        assert_eq!(
            device.status(&hardware).unwrap()["last_error"],
            "DeviceDisconnected"
        );
    }
    #[test]
    fn follow_rejects_simulated_sources_and_does_nothing_before_connect() {
        let hardware = Fake::default();
        let device = Device::default();
        let mut status = agent_status("thinking", "#06B6D4");
        device.follow_status(&hardware, Some(&status)).unwrap();
        assert!(hardware.calls.lock().unwrap().is_empty());
        device.connect_hardware(&hardware).unwrap();
        device.start_following(&hardware).unwrap();
        status["result"]["backend"] = json!("simulated");
        assert_eq!(
            device.follow_status(&hardware, Some(&status)).unwrap_err(),
            "SimulationNotAllowed"
        );
        assert!(hardware
            .calls
            .lock()
            .unwrap()
            .iter()
            .all(|s| s == "inspect"));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn invalid_source_restores_an_owned_color_before_pausing() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        device.start_following(&hardware).unwrap();
        device
            .follow_status(&hardware, Some(&agent_status("thinking", "#06B6D4")))
            .unwrap();
        assert_eq!(
            device
                .follow_status(&hardware, Some(&agent_status("invalid", "#06B6D4")))
                .unwrap_err(),
            "InvalidAgentStatus"
        );
        let state = device.status(&hardware).unwrap();
        assert_eq!(state["recovery_pending"], false);
        assert_eq!(state["last_error"], "InvalidAgentStatus");
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|s| *s == "restore")
                .count(),
            1
        );
    }
    #[test]
    fn unplug_locks_session_and_requires_explicit_reconnection() {
        let hardware = Fake::default();
        let device = Device::default();
        assert_eq!(device.require_connected().unwrap_err(), "NotConnected");
        let connected = device.connect_hardware(&hardware).unwrap();
        device.require_connected().unwrap();
        assert_eq!(connected["main"]["mode"], "effect");
        assert!(connected["main"]["color"].is_null());
        hardware.snapshot.lock().unwrap()["probe"] = Value::Null;
        let lost = device.status(&hardware).unwrap();
        assert_eq!(lost["connected"], false);
        assert_eq!(device.require_connected().unwrap_err(), "NotConnected");
        assert_eq!(lost["reconnecting"], false);
        hardware.snapshot.lock().unwrap()["probe"] = probe();
        let attempts = hardware.calls.lock().unwrap().len();
        assert_eq!(device.status(&hardware).unwrap()["connected"], false);
        assert_eq!(hardware.calls.lock().unwrap().len(), attempts);
        assert_eq!(
            device.connect_hardware(&hardware).unwrap()["connected"],
            true
        );
        device.disconnect(&hardware).unwrap();
        let calls = hardware.calls.lock().unwrap().len();
        assert_eq!(device.status(&hardware).unwrap()["reconnecting"], false);
        assert_eq!(hardware.calls.lock().unwrap().len(), calls);
        assert!(hardware
            .calls
            .lock()
            .unwrap()
            .iter()
            .all(|call| call == "inspect"));
    }
    #[test]
    fn reconnect_never_switches_to_a_different_identity_or_publishes_it() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        hardware.snapshot.lock().unwrap()["probe"]["fingerprint"] = json!("b".repeat(64));
        let lost = device.status(&hardware).unwrap();
        assert_eq!(lost["connected"], false);
        assert_eq!(lost["last_error"], "DeviceChanged");
        assert!(!lost.to_string().contains("fingerprint"));
        hardware.snapshot.lock().unwrap()["probe"] = probe();
        assert_eq!(device.status(&hardware).unwrap()["connected"], false);
        assert_eq!(
            device.connect_hardware(&hardware).unwrap()["connected"],
            true
        );
    }
    #[test]
    fn damaged_probe_never_panics_or_remains_connected() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        hardware.snapshot.lock().unwrap()["probe"]["state"] = json!([3, 15]);
        let status = device.status(&hardware).unwrap();
        assert_eq!(status["connected"], false);
        assert_eq!(status["last_error"], "InvalidDeviceReply");
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn persisted_capture_requires_explicit_restore_after_app_restart() {
        let hardware = Fake::default();
        let first = Device::default();
        first.connect_hardware(&hardware).unwrap();
        let applied = first
            .apply(
                &hardware,
                "nuphy-kick75-io",
                &json!({"color":"#18C7AA","brightness":15}),
            )
            .unwrap();
        assert_eq!(applied["main"]["mode"], "solid");
        assert_eq!(applied["main"]["color"], "#18C7AA");
        let restarted = Device::default();
        let recovered = restarted.connect_hardware(&hardware).unwrap();
        assert_eq!(recovered["recovery_required"], true);
        assert_eq!(recovered["can_restore"], true);
        assert_eq!(
            restarted
                .apply(&hardware, "nuphy-kick75-io", &json!({}))
                .unwrap_err(),
            "RecoveryRequired"
        );
        // Merely connecting/quitting does not claim an earlier capture.
        restarted.shutdown(&hardware).unwrap();
        assert!(!hardware
            .calls
            .lock()
            .unwrap()
            .iter()
            .any(|call| call == "restore"));
        let recovery = Device::default();
        recovery.connect_hardware(&hardware).unwrap();
        assert_eq!(
            recovery.restore(&hardware).unwrap()["recovery_pending"],
            false
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn ambiguous_write_keeps_recovery_across_unplug_and_blocks_another_apply() {
        let hardware = Fake {
            ambiguous: true,
            ..Fake::default()
        };
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        assert_eq!(
            device
                .apply(&hardware, "nuphy-kick75-io", &json!({}))
                .unwrap_err(),
            "DeviceDisconnected"
        );
        let lost = device.status(&hardware).unwrap();
        assert_eq!(lost["connected"], false);
        assert_eq!(lost["recovery_pending"], true);
        hardware.snapshot.lock().unwrap()["probe"] = probe();
        assert_eq!(device.status(&hardware).unwrap()["connected"], false);
        let reconnected = device.connect_hardware(&hardware).unwrap();
        assert_eq!(reconnected["recovery_required"], true);
        assert_eq!(
            device
                .apply(&hardware, "nuphy-kick75-io", &json!({}))
                .unwrap_err(),
            "RecoveryRequired"
        );
        device.restore(&hardware).unwrap();
        assert_eq!(
            hardware
                .calls
                .lock()
                .unwrap()
                .iter()
                .filter(|call| call.as_str() == "apply")
                .count(),
            1
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn owned_main_capture_is_restored_on_disconnect_and_shutdown_rejects_new_writes() {
        let hardware = Fake::default();
        let device = Device::default();
        device.connect_hardware(&hardware).unwrap();
        device
            .apply(&hardware, "nuphy-kick75-io", &json!({}))
            .unwrap();
        device.disconnect(&hardware).unwrap();
        assert_eq!(hardware.calls.lock().unwrap().last().unwrap(), "restore");
        device.shutdown(&hardware).unwrap();
        assert_eq!(
            device.connect_hardware(&hardware).unwrap_err(),
            "AppClosing"
        );
        assert_eq!(
            device
                .apply(&hardware, "nuphy-kick75-io", &json!({}))
                .unwrap_err(),
            "AppClosing"
        );
    }
    #[test]
    #[ignore = "Requires an explicitly authorized USB Kick75 Mac-profile hardware test"]
    fn manual_follow_real_core_stream_and_restore() {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let binary = std::env::var_os("KEYFLUX_TEST_CORE").expect("built Zig CLI");
        let directory = std::path::PathBuf::from("/private/tmp")
            .join(format!("keyflux-follow-hardware-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let core = Core::new(binary.clone().into(), Some(directory.clone()), false);
        core.ensure().unwrap();
        let device = Device::default();
        struct Guard<'a>(&'a Device, &'a Core);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                let _ = self.0.shutdown(self.1);
                self.1.stop_owned();
            }
        }
        let guard = Guard(&device, &core);
        let before = core.probe_device().unwrap();
        device.connect(&core).unwrap();
        device.start_following(&core).unwrap();
        core.call("theme-set", Some(&json!({"signals":{"working":{"color":"#06B6D4","brightness":15},"output":{"color":"#8B5CF6","brightness":15}}}))).unwrap();
        let emit = |kind: &str| {
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            let event = json!({"schema_version":1,"provider":"keyflux.hardware-verification","session_id":"hardware-follow-test","turn_id":"controlled-turn","event_id":format!("{kind}-{timestamp}"),"timestamp_ns":timestamp,"kind":kind});
            let mut child = Command::new(&binary)
                .args(["emit", "--state-dir"])
                .arg(&directory)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(&serde_json::to_vec(&event).unwrap())
                .unwrap();
            assert!(child.wait_with_output().unwrap().status.success());
        };
        for kind in ["turn_started", "output"] {
            emit(kind);
            device.follow_core(&core);
            let state = device.status(&core).unwrap();
            assert_eq!(state["main"]["mode"], "solid");
            assert_eq!(state["main"]["brightness"], 15);
            assert!(state["last_error"].is_null());
            assert_eq!(core.probe_device().unwrap()["state"], state["state"]);
            device.follow_core(&core); // Repeated snapshots do not reapply.
        }
        emit("turn_cancelled");
        device.follow_core(&core);
        assert_eq!(core.probe_device().unwrap()["state"], before["state"]);
        assert_eq!(device.status(&core).unwrap()["recovery_pending"], false);
        drop(guard);
        std::fs::remove_dir_all(directory).unwrap();
        println!("Controlled real-core events -> automatic USB main colors -> exact original restoration passed. This is not a real Codex export test.");
    }
    #[test]
    #[ignore = "Uses real Codex Desktop records and the connected USB Kick75, then restores its original effect"]
    fn manual_real_desktop_to_kick75() {
        let binary = std::env::var_os("KEYFLUX_TEST_CORE").expect("built Zig core");
        let directory = std::path::PathBuf::from("/private/tmp")
            .join(format!("keyflux-live-hid-{}", crate::codex::now_ns()));
        std::fs::create_dir(&directory).unwrap();
        let core = Core::new(binary.into(), Some(directory.clone()), false);
        core.ensure().unwrap();
        let device = Device::default();
        struct Finish<'a>(&'a Device, &'a Core);
        impl Drop for Finish<'_> {
            fn drop(&mut self) {
                let _ = self.0.shutdown(self.1);
                self.1.stop_owned();
            }
        }
        let finish = Finish(&device, &core);
        core.call("theme-set",Some(&json!({"signals":{"working":{"color":"#3B82F6","brightness":15},"tool":{"color":"#8B5CF6","brightness":15},"attention":{"color":"#FF9500","brightness":15},"complete":{"color":"#22C55E","brightness":15}}}))).unwrap();
        let source = crate::codex::Source::default();
        source.poll(&core);
        assert_eq!(source.snapshot()["available"], true);
        assert!(source.snapshot()["active_sessions"].as_u64().unwrap() > 0);
        device.connect(&core).unwrap();
        device.start_following(&core).unwrap();
        let before = core.probe_device().unwrap();
        for _ in 0..3 {
            source.poll(&core);
            let state = core.call("status", None).unwrap();
            assert!(matches!(
                state["result"]["state"]["phase"].as_str(),
                Some("working" | "tool" | "attention")
            ));
            device.follow_core(&core);
            let actual = core.probe_device().unwrap();
            let shown = device.status(&core).unwrap();
            assert_eq!(shown["main"]["mode"], "solid");
            assert_eq!(shown["main"]["brightness"], 15);
            assert_eq!(actual["state"], shown["state"]);
            assert_eq!(
                actual["state"].as_array().unwrap()[9..],
                before["state"].as_array().unwrap()[9..]
            );
            println!("Real Desktop phase {} -> acknowledged USB color {}, brightness 15%; side unchanged.",state["result"]["state"]["phase"],shown["main"]["color"]);
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        device.disconnect(&core).unwrap();
        assert_eq!(core.probe_device().unwrap()["state"], before["state"]);
        println!("Real Desktop source -> Zig aggregate -> USB main light readback passed; original 17-byte state restored exactly. No synthetic source events were submitted.");
        drop(finish);
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    #[ignore = "Requires an explicitly authorized USB Kick75 Mac-profile hardware test"]
    fn manual_kick75_connection_apply_readback_and_restore() {
        let binary = std::env::var_os("KEYFLUX_TEST_CORE").expect("built Zig CLI");
        let core = Core::new(binary.into(), None, false);
        let before = core.probe_device().unwrap();
        let device = Device::default();
        struct Restore<'a>(&'a Device, &'a Core);
        impl Drop for Restore<'_> {
            fn drop(&mut self) {
                let _ = self.0.shutdown(self.1);
            }
        }
        let guard = Restore(&device, &core);
        let connected = device.connect(&core).unwrap();
        assert_eq!(connected["writable"], true);
        let applied = device
            .apply(
                &core,
                "nuphy-kick75-io",
                &json!({"color":"#18C7AA","brightness":15}),
            )
            .unwrap();
        assert_eq!(applied["connected"], true);
        std::thread::sleep(std::time::Duration::from_secs(2));
        let readback = core.probe_device().unwrap();
        assert_eq!(readback["state"], applied["state"]);
        let status = device.status(&core).unwrap();
        assert_eq!(status["main"]["mode"], "solid");
        assert_eq!(status["main"]["brightness"], 15);
        assert_eq!(status["recovery_pending"], true);
        assert_eq!(status["recovery_required"], false);
        let restarted = Device::default();
        let recovery = restarted.connect(&core).unwrap();
        assert_eq!(recovery["recovery_required"], true);
        assert_eq!(recovery["can_restore"], true);
        assert_eq!(
            restarted
                .apply(
                    &core,
                    "nuphy-kick75-io",
                    &json!({"color":"#FF0000","brightness":15})
                )
                .unwrap_err(),
            "RecoveryRequired"
        );
        restarted.shutdown(&core).unwrap(); // An unowned capture is not restored on Quit.
        assert_eq!(core.probe_device().unwrap()["state"], readback["state"]);
        device.restore(&core).unwrap();
        let after = core.probe_device().unwrap();
        assert_eq!(before["state"], after["state"]);
        assert_eq!(device.status(&core).unwrap()["recovery_pending"], false);
        device.disconnect(&core).unwrap();
        drop(guard);
        println!("USB connect, solid apply, actual readback and exact original restoration passed; side unchanged.");
    }
    #[test]
    fn disconnected_session_never_launches_hardware() {
        let core = Core::new("not-executed".into(), None, false);
        let device = Device::default();
        assert_eq!(device.status(&core).unwrap()["connected"], false);
        assert_eq!(
            device
                .apply(&core, "nuphy-kick75-io", &json!({}))
                .unwrap_err(),
            "NotConnected"
        );
        assert_eq!(device.restore(&core).unwrap_err(), "NotConnected");
        device.shutdown(&core).unwrap();
    }
    #[test]
    fn unknown_firmware_is_never_writable() {
        let mut unknown = probe();
        unknown["firmware"][2] = json!(5);
        assert!(valid_probe(&unknown));
        assert!(!writable(&unknown));
    }
}
