// Subprocess plumbing: template substitution, capture with timeout, inherit.
// Every command string the picker runs comes from herdr-pick.json.

use serde_json::Value;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Out {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

pub fn subst(args: &[String], vars: &[(&str, &str)]) -> Vec<String> {
    args.iter().map(|a| subst_str(a, vars)).collect()
}

pub fn subst_str(s: &str, vars: &[(&str, &str)]) -> String {
    let mut out = s.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{k}}}"), v);
    }
    out
}

fn read_all(mut r: impl Read) -> Vec<u8> {
    let mut b = Vec::new();
    let _ = r.read_to_end(&mut b);
    b
}

pub fn run(program: &str, args: &[String], timeout: Duration) -> Result<Out, String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{program}: {e}"))?;
    let so = child.stdout.take();
    let se = child.stderr.take();
    let result = std::thread::scope(|scope| -> Result<Out, String> {
        let h1 = scope.spawn(move || so.map(read_all).unwrap_or_default());
        let h2 = scope.spawn(move || se.map(read_all).unwrap_or_default());
        let start = Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(st)) => break st,
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(format!("{program}: timeout"));
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => return Err(format!("{program}: {e}")),
            }
        };
        let stdout = String::from_utf8_lossy(&h1.join().unwrap_or_default()).into_owned();
        let stderr = String::from_utf8_lossy(&h2.join().unwrap_or_default()).into_owned();
        Ok(Out {
            status: status.code().unwrap_or(-1),
            stdout,
            stderr,
        })
    });
    result
}

/// Run a script with stdin inherited, stdout captured (create_scratch.sh).
pub fn run_script_capture(program: &str, args: &[String]) -> Result<(i32, String), String> {
    let child = Command::new(program)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("{program}: {e}"))?;
    let mut child = child;
    let mut so = child.stdout.take().unwrap();
    let reader = std::thread::spawn(move || read_all(&mut so));
    let status = child.wait().map_err(|e| format!("{program}: {e}"))?;
    let out = String::from_utf8_lossy(&reader.join().unwrap_or_default()).into_owned();
    Ok((status.code().unwrap_or(-1), out))
}

/// Parse a JSON document from command output; `error` objects become Err.
pub fn parse_json(out: &Out, what: &str) -> Result<Value, String> {
    if out.status != 0 {
        let msg = out.stderr.lines().next().unwrap_or("").trim().to_string();
        return Err(if msg.is_empty() {
            format!("{what}: exit {}", out.status)
        } else {
            format!("{what}: {msg}")
        });
    }
    let v: Value = serde_json::from_str(out.stdout.trim()).map_err(|e| format!("{what}: {e}"))?;
    if let Some(err) = v.get("error") {
        let msg = err
            .get("message")
            .and_then(|m| m.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| err.to_string());
        return Err(msg);
    }
    Ok(v)
}
