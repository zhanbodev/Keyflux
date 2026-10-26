use crate::core::Core;
use serde_json::{json, Value};
use std::sync::Mutex;

#[derive(Default)]
struct Session {
    probe: Option<Value>,
    restore_owned: bool,
    identity: Option<String>,
    closing: bool,
}
#[derive(Default)]
pub struct Device {
    session: Mutex<Session>,
}
fn writable(probe: &Value) -> bool {
    cfg!(target_os = "macos")
        && probe["schema_version"] == 1
        && probe["model_id"] == "nuphy-kick75-io"
        && probe["profile"] == 0
        && probe["led_count"] == 85
        && probe["input_bytes"] == 64
        && probe["output_bytes"] == 64
        && probe["firmware"].as_array().is_some_and(|v| {
            v.len() == 8
                && v[..6]
                    == [
                        json!(18),
                        json!(0),
                        json!(4),
                        json!(170),
                        json!(6),
                        json!(0),
                    ]
        })
        && probe["geometry"].as_array().is_some_and(|v| {
            v.len() == 8 && v[..5] == [json!(0), json!(8), json!(4), json!(6), json!(15)]
        })
}
fn public(probe: Option<&Value>, recovery: bool) -> Value {
    let Some(probe) = probe else {
        return json!({"connected":false,"writable":false,"recovery_pending":recovery});
    };
    let f = &probe["firmware"];
    json!({"connected":true,"model_id":probe["model_id"],"firmware":format!("{}.{}.{}.{}",f[2],f[1],f[0],f[4].as_u64().unwrap_or(0) | (f[5].as_u64().unwrap_or(0) << 8)),"profile":if probe["profile"]==0 {"Mac"} else {"Win"},"writable":writable(probe),"recovery_pending":recovery,"state":probe["state"]})
}
impl Device {
    pub fn connect(&self, core: &Core) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if session.closing {
            return Err("AppClosing".into());
        }
        if core.simulated {
            return Err("SimulationNotAllowed".into());
        }
        let probe = core.probe_device()?;
        if let Some(old) = &session.probe {
            if old["fingerprint"] != probe["fingerprint"] {
                return Err("DeviceChanged".into());
            }
        }
        let identity = probe["fingerprint"].as_str().ok_or("InvalidDeviceReply")?;
        if identity.len() != 64 || probe["model_id"] != "nuphy-kick75-io" {
            return Err("InvalidDeviceReply".into());
        }
        if session.restore_owned && session.identity.as_deref() != Some(identity) {
            return Err("DeviceChanged".into());
        }
        session.identity = Some(identity.to_owned());
        session.probe = Some(probe);
        Ok(public(session.probe.as_ref(), session.restore_owned))
    }
    pub fn status(&self, core: &Core) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if let Some(old) = &session.probe {
            match core.probe_device() {
                Ok(probe) if old["fingerprint"] == probe["fingerprint"] => {
                    session.probe = Some(probe)
                }
                _ => {
                    session.probe = None;
                }
            }
        }
        Ok(public(session.probe.as_ref(), session.restore_owned))
    }
    pub fn apply(&self, core: &Core, model: &str, signal: &Value) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
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
        let identity = probe["fingerprint"]
            .as_str()
            .ok_or("InvalidDeviceIdentity")?;
        let result = core.apply_device(signal, identity)?;
        if result["changed"] == true {
            session.restore_owned = true;
        }
        let mut next = session.probe.take().ok_or("NotConnected")?;
        next["state"] = result["state"].clone();
        session.probe = Some(next);
        Ok(public(session.probe.as_ref(), session.restore_owned))
    }
    pub fn restore(&self, core: &Core) -> Result<Value, String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        if !writable(session.probe.as_ref().ok_or("NotConnected")?) {
            return Err("UnverifiedDevice".into());
        }
        let identity = session.probe.as_ref().ok_or("NotConnected")?["fingerprint"]
            .as_str()
            .ok_or("InvalidDeviceIdentity")?
            .to_owned();
        let result = core.restore_device(&identity)?;
        if let Some(probe) = session.probe.as_mut() {
            if result.get("state").is_some() {
                probe["state"] = result["state"].clone();
            }
        }
        session.restore_owned = false;
        let mut state = public(session.probe.as_ref(), false);
        state["restored"] = result["restored"].clone();
        Ok(state)
    }
    pub fn disconnect(&self, core: &Core) -> Result<Value, String> {
        self.finish(core, false)?;
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        session.probe = None;
        Ok(public(None, session.restore_owned))
    }
    pub fn shutdown(&self, core: &Core) -> Result<(), String> {
        self.finish(core, true)
    }
    fn finish(&self, core: &Core, closing: bool) -> Result<(), String> {
        let mut session = self.session.lock().map_err(|_| "DeviceLockFailed")?;
        session.closing |= closing;
        let owned = session.restore_owned;
        drop(session);
        if owned {
            self.restore(core)?;
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
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
        device.restore(&core).unwrap();
        let after = core.probe_device().unwrap();
        assert_eq!(before["state"], after["state"]);
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
        let probe = json!({"schema_version":1,"model_id":"nuphy-kick75-io","profile":0,"led_count":85,"input_bytes":64,"output_bytes":64,"firmware":[18,0,5,170,6,0,247,247],"geometry":[0,8,4,6,15,130,247,247]});
        assert!(!writable(&probe));
    }
}
