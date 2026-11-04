//! integrations/claude-code/background-waiting-hook.sh against a fake `hc` and a session
//! file the test controls: what it reports, and when.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const HOOK: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/integrations/claude-code/background-waiting-hook.sh");

struct Claude {
    dir: PathBuf,
}

impl Claude {
    fn new(name: &str) -> Claude {
        let dir = std::env::temp_dir().join(format!("herdr-background-waiting-hook-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sessions")).unwrap();
        // Logs each call, one line per report body.
        let hc = dir.join("hc");
        std::fs::write(&hc, format!("#!/bin/sh\nprintf '%s\\n' \"$2\" >> {}/calls\n", dir.display())).unwrap();
        Command::new("chmod").arg("+x").arg(&hc).status().unwrap();
        Claude { dir }
    }

    /// Claude's session file, written the way a person might format it.
    fn status(&self, status: &str) {
        let json = format!("{{\n  \"pid\": 1,\n  \"sessionId\": \"S-1\",\n  \"status\": \"{status}\"\n}}\n");
        std::fs::write(self.dir.join("sessions/1.json.tmp"), json).unwrap();
        std::fs::rename(self.dir.join("sessions/1.json.tmp"), self.dir.join("sessions/1.json")).unwrap();
    }

    /// One Stop hook run; returns once the hook process does.
    fn stop(&self) {
        let mut child = Command::new("sh")
            .arg(HOOK)
            .env("HC_TERMINAL_ID", "t1")
            .env("HERDR_HC", self.dir.join("hc"))
            .env("HERDR_BACKGROUND_WAITING_POLL", "0.1")
            .env("CLAUDE_CONFIG_DIR", &self.dir)
            .env("TMPDIR", &self.dir)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        child.stdin.take().unwrap().write_all(br#"{"session_id": "S-1", "hook_event_name": "Stop"}"#).unwrap();
        assert!(child.wait().unwrap().success());
    }

    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("calls")).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    /// What the record is now, from the last report: working, cleared, or never sent.
    fn record(&self) -> Option<&'static str> {
        self.calls().last().map(|c| if c == "state=working:id=bg" { "working" } else { "cleared" })
    }

    fn eventually(&self, want: Option<&'static str>) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.record() != want {
            assert!(Instant::now() < deadline, "record {:?}, want {want:?}; calls {:?}", self.record(), self.calls());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Holds the record where it is for a while (the watcher has polled several times).
    fn stays(&self, want: Option<&'static str>) {
        for _ in 0..10 {
            std::thread::sleep(Duration::from_millis(50));
            assert_eq!(self.record(), want, "calls {:?}", self.calls());
        }
    }
}

impl Drop for Claude {
    fn drop(&mut self) {
        // Ends a watcher still polling, then the files.
        self.status("idle");
        std::thread::sleep(Duration::from_millis(300));
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn lock_left(dir: &Path) -> bool {
    std::fs::read_dir(dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().starts_with("herdr-background-waiting-"))
}

#[test]
fn background_work_is_reported_before_the_hook_returns() {
    // Claude may show its own `done` right after the hook: the record has to be there already.
    let c = Claude::new("sync");
    c.status("shell");
    c.stop();
    assert_eq!(c.record(), Some("working"), "reported synchronously");
    c.status("idle");
    c.eventually(Some("cleared"));
    let deadline = Instant::now() + Duration::from_secs(2);
    while lock_left(&c.dir) {
        assert!(Instant::now() < deadline, "the watcher cleans up its lock");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_session_still_saying_busy_at_stop_is_reported_once_it_settles() {
    let c = Claude::new("settle");
    c.status("busy");
    c.stop();
    c.status("shell");
    c.eventually(Some("working"));
    c.status("idle");
    c.eventually(Some("cleared"));
}

#[test]
fn no_background_work_reports_nothing() {
    let c = Claude::new("none");
    c.status("idle");
    c.stop();
    c.stays(None);
}

#[test]
fn a_new_turn_hands_off_to_the_next_stop() {
    let c = Claude::new("handoff");
    c.status("shell");
    c.stop();
    c.eventually(Some("working"));
    // The person sends a prompt: busy. That turn ends quickly, before the first
    // watcher noticed busy, and again leaves a shell running.
    c.status("busy");
    c.stop();
    std::thread::sleep(Duration::from_millis(300));
    c.status("shell");
    c.eventually(Some("working"));
    c.stays(Some("working"));
    c.status("idle");
    c.eventually(Some("cleared"));
}
