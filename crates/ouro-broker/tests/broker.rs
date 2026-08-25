use ouro_broker::{
    Broker, BrokerConfig, Command, ErrorCode, Recovery, Reply, Request, ServerBody, ServerMessage,
    TerminalSummary, BROKER_BUILD, CAPABILITY_CANONICAL_RECOVERY, CAPABILITY_CREATE_IDEMPOTENCY,
    CAPABILITY_DELTA_RESUME, CAPABILITY_REAPED_TERMINATION, PROTOCOL_VERSION,
};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command as ProcessCommand, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

struct BrokerProcess {
    child: Child,
    _directory: TempDir,
    socket: PathBuf,
}

impl BrokerProcess {
    fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker.sock");
        let child = ProcessCommand::new(env!("CARGO_BIN_EXE_ouro-broker"))
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            assert!(Instant::now() < deadline, "broker socket was not created");
            thread::sleep(Duration::from_millis(10));
        }
        Self {
            child,
            _directory: directory,
            socket,
        }
    }
}

impl Drop for BrokerProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct TestClient {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    generation: u64,
    next_id: u64,
    client_id: u64,
}

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

impl TestClient {
    fn connect(path: &Path) -> Self {
        let deadline = Instant::now() + Duration::from_secs(5);
        let writer = loop {
            match UnixStream::connect(path) {
                Ok(stream) => break stream,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                    ) && Instant::now() < deadline =>
                {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("could not connect to broker: {error}"),
            }
        };
        writer
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        writer
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let reader = BufReader::new(writer.try_clone().unwrap());
        let mut client = Self {
            writer,
            reader,
            generation: 0,
            next_id: 1,
            client_id: NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed),
        };
        let hello = client.read_message();
        assert_eq!(hello.version, PROTOCOL_VERSION);
        match &hello.body {
            ServerBody::Hello {
                pid,
                build,
                capabilities,
            } => {
                assert!(*pid > 0);
                assert_eq!(build, BROKER_BUILD);
                assert_eq!(
                    capabilities,
                    &[
                        CAPABILITY_CANONICAL_RECOVERY,
                        CAPABILITY_DELTA_RESUME,
                        CAPABILITY_CREATE_IDEMPOTENCY,
                        CAPABILITY_REAPED_TERMINATION,
                    ]
                );
            }
            other => panic!("expected negotiated hello, got {other:?}"),
        }
        client.generation = hello.broker_generation;
        client
    }

    fn request(&mut self, command: Command) -> ServerMessage {
        let id = self.next_id;
        self.next_id += 1;
        let request = Request {
            version: PROTOCOL_VERSION,
            id,
            command,
        };
        serde_json::to_writer(&mut self.writer, &request).unwrap();
        self.writer.write_all(b"\n").unwrap();
        self.writer.flush().unwrap();
        loop {
            let message = self.read_message();
            match message.body {
                ServerBody::Reply {
                    id: response_id, ..
                }
                | ServerBody::Error {
                    id: response_id, ..
                } if response_id == id => return message,
                _ => {}
            }
        }
    }

    fn read_message(&mut self) -> ServerMessage {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        assert!(!line.is_empty(), "broker disconnected");
        serde_json::from_str(&line).unwrap()
    }

    fn create(&mut self, program: &str, args: Vec<String>) -> TerminalSummary {
        let create_nonce = format!("test-create-{}-{}", self.client_id, self.next_id);
        let message = self.request(Command::Create {
            create_nonce,
            program: program.into(),
            args,
            current_directory: None,
            environment: Default::default(),
            columns: 80,
            rows: 24,
        });
        match message.body {
            ServerBody::Reply {
                result: Reply::Created { terminal },
                ..
            } => terminal,
            other => panic!("create failed: {other:?}"),
        }
    }

    fn attach(&mut self, terminal_id: &str, after_cursor: Option<u64>) -> AttachResult {
        let message = self.request(Command::Attach {
            terminal_id: terminal_id.into(),
            broker_generation: self.generation,
            after_cursor,
        });
        match message.body {
            ServerBody::Reply {
                result:
                    Reply::Attached {
                        terminal,
                        input_epoch,
                        lease_id,
                        recovery,
                    },
                ..
            } => AttachResult {
                terminal,
                input_epoch,
                lease_id,
                recovery,
            },
            other => panic!("attach failed: {other:?}"),
        }
    }

    fn list(&mut self) -> Vec<TerminalSummary> {
        match self.request(Command::List).body {
            ServerBody::Reply {
                result: Reply::Listed { terminals },
                ..
            } => terminals,
            other => panic!("list failed: {other:?}"),
        }
    }

    fn input(&mut self, attachment: &AttachResult, data: &[u8]) {
        let message = self.request(Command::Input {
            terminal_id: attachment.terminal.id.clone(),
            broker_generation: self.generation,
            input_epoch: attachment.input_epoch,
            lease_id: attachment.lease_id.clone(),
            data: data.to_vec(),
        });
        assert!(matches!(
            message.body,
            ServerBody::Reply {
                result: Reply::Accepted,
                ..
            }
        ));
    }
}

#[test]
fn v3_socket_namespace_coexists_with_live_v2_listener() {
    let directory = tempfile::tempdir().unwrap();
    let v2_path = directory.path().join("broker-v2.sock");
    let v3_path = directory.path().join("broker-v3.sock");
    let v2_listener = UnixListener::bind(&v2_path).unwrap();

    let broker = Broker::bind(BrokerConfig::new(&v3_path)).unwrap();
    assert!(
        v2_path.exists(),
        "binding v3 must leave the v2 socket intact"
    );
    assert!(v3_path.exists());
    let _v2_client = UnixStream::connect(&v2_path).unwrap();

    drop(broker);
    assert!(
        v2_path.exists(),
        "dropping v3 must not unlink the v2 namespace"
    );
    drop(v2_listener);
}

struct AttachResult {
    terminal: TerminalSummary,
    input_epoch: u64,
    lease_id: String,
    recovery: Recovery,
}

fn assert_error(message: ServerMessage, expected: ErrorCode) {
    match message.body {
        ServerBody::Error { code, .. } => assert_eq!(code, expected),
        other => panic!("expected {expected:?}, got {other:?}"),
    }
}

fn recovery_bytes(recovery: &Recovery) -> Vec<u8> {
    match recovery {
        Recovery::Snapshot { data, .. } => data.clone(),
        Recovery::Resume { deltas } => deltas
            .iter()
            .flat_map(|delta| delta.data.iter().copied())
            .collect(),
    }
}

fn wait_until_stopped(client: &mut TestClient, terminal_id: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if client
            .list()
            .iter()
            .find(|terminal| terminal.id == terminal_id)
            .is_some_and(|terminal| !terminal.running)
        {
            return;
        }
        assert!(Instant::now() < deadline, "terminal was not reaped");
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn carriage_return_executes_a_command_through_the_pty_line_discipline() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let terminal = client.create("/bin/sh", vec!["-s".into()]);
    let authority = client.attach(&terminal.id, None);

    // Terminal keyboards send CR. The slave PTY's canonical line discipline
    // must map it to NL before the shell reads the completed input line.
    client.input(&authority, b"exit\r");

    wait_until_stopped(&mut client, &terminal.id);
}

#[test]
fn create_reports_exec_and_chdir_failures_without_leaving_zombies() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);

    let missing_executable = client.request(Command::Create {
        create_nonce: "missing-executable".into(),
        program: "/definitely/missing/ourocode-command".into(),
        args: Vec::new(),
        current_directory: None,
        environment: Default::default(),
        columns: 80,
        rows: 24,
    });
    assert_error(missing_executable, ErrorCode::SpawnFailed);

    let missing_directory = client.request(Command::Create {
        create_nonce: "missing-directory".into(),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "exit 0".into()],
        current_directory: Some("/definitely/missing/ourocode-directory".into()),
        environment: Default::default(),
        columns: 80,
        rows: 24,
    });
    assert_error(missing_directory, ErrorCode::SpawnFailed);

    let child_states = ProcessCommand::new("ps")
        .args(["-a", "-x", "-o", "ppid=,stat="])
        .output()
        .unwrap();
    assert!(child_states.status.success());
    let broker_pid = broker.child.id().to_string();
    assert!(
        !String::from_utf8_lossy(&child_states.stdout)
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                Some((fields.next()?, fields.next()?))
            })
            .any(|(parent_pid, state)| parent_pid == broker_pid && state.starts_with('Z')),
        "spawn failure left a zombie child"
    );

    let healthy = client.create("/bin/sh", vec!["-c".into(), "exit 0".into()]);
    wait_until_stopped(&mut client, &healthy.id);
}

#[test]
fn create_nonce_is_idempotent_and_conflicts_fail_closed() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let create = |program: &str| Command::Create {
        create_nonce: "stable-create-nonce".into(),
        program: program.into(),
        args: vec!["-c".into(), "sleep 30".into()],
        current_directory: None,
        environment: Default::default(),
        columns: 80,
        rows: 24,
    };

    let first = match client.request(create("/bin/sh")).body {
        ServerBody::Reply {
            result: Reply::Created { terminal },
            ..
        } => terminal,
        other => panic!("first create failed: {other:?}"),
    };
    let replay = match client.request(create("/bin/sh")).body {
        ServerBody::Reply {
            result: Reply::Created { terminal },
            ..
        } => terminal,
        other => panic!("idempotent create failed: {other:?}"),
    };
    assert_eq!(first.id, replay.id);
    assert_eq!(client.list().iter().filter(|item| item.running).count(), 1);

    let conflict = client.request(create("/bin/zsh"));
    assert_error(conflict, ErrorCode::BadRequest);

    let terminated = client.request(Command::Terminate {
        terminal_id: first.id.clone(),
        broker_generation: client.generation,
    });
    assert!(matches!(
        terminated.body,
        ServerBody::Reply {
            result: Reply::Accepted,
            ..
        }
    ));
    let tombstone_replay = match client.request(create("/bin/sh")).body {
        ServerBody::Reply {
            result: Reply::Created { terminal },
            ..
        } => terminal,
        other => panic!("tombstone create replay failed: {other:?}"),
    };
    assert_eq!(first.id, tombstone_replay.id);
    assert!(!tombstone_replay.running);
}

#[test]
fn exited_terminals_release_live_capacity_and_tombstones_are_bounded_and_forgettable() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let mut newest_id = String::new();

    for _ in 0..70 {
        let terminal = client.create("/bin/sh", vec!["-c".into(), "exit 0".into()]);
        newest_id = terminal.id;
        wait_until_stopped(&mut client, &newest_id);
    }

    let tombstones = client.list();
    assert!(tombstones.len() <= 64, "tombstone bound was exceeded");
    assert!(tombstones.iter().all(|terminal| !terminal.running));
    assert!(tombstones.iter().any(|terminal| terminal.id == newest_id));

    let forgot = client.request(Command::Forget {
        terminal_id: newest_id.clone(),
        broker_generation: client.generation,
    });
    assert!(matches!(
        forgot.body,
        ServerBody::Reply {
            result: Reply::Accepted,
            ..
        }
    ));
    assert!(client
        .list()
        .iter()
        .all(|terminal| terminal.id != newest_id));

    let live = client.create("/bin/sh", vec!["-c".into(), "sleep 1".into()]);
    assert!(
        client
            .list()
            .iter()
            .any(|terminal| terminal.id == live.id && terminal.running),
        "exited terminals consumed the live terminal capacity"
    );
}

#[test]
fn noisy_terminal_does_not_starve_an_independent_marker_terminal() {
    let broker = BrokerProcess::start();
    let mut noisy_client = TestClient::connect(&broker.socket);
    let noisy = noisy_client.create("/bin/sh", vec!["-c".into(), "yes noise".into()]);
    let _ = noisy_client.attach(&noisy.id, None);

    let mut marker_client = TestClient::connect(&broker.socket);
    let marker = marker_client.create(
        "/bin/sh",
        vec![
            "-c".into(),
            "sleep 0.05; printf ourocode-marker; sleep 1".into(),
        ],
    );
    let attached = marker_client.attach(&marker.id, None);
    let mut output = recovery_bytes(&attached.recovery);
    let deadline = Instant::now() + Duration::from_secs(2);
    while !output
        .windows(b"ourocode-marker".len())
        .any(|bytes| bytes == b"ourocode-marker")
    {
        assert!(Instant::now() < deadline, "marker terminal was starved");
        if let ServerBody::Output {
            terminal_id, data, ..
        } = marker_client.read_message().body
        {
            if terminal_id == marker.id {
                output.extend(data);
            }
        }
    }
}

#[test]
fn reset_recovery_is_versioned_canonical_ansi_not_a_raw_tail() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let terminal = client.create(
        "/bin/sh",
        vec![
            "-c".into(),
            "printf '\\033[31;1mred\\033[0m\\r\\n'; sleep 30".into(),
        ],
    );

    let deadline = Instant::now() + Duration::from_secs(3);
    let first = client.attach(&terminal.id, None);
    let mut cursor = first.terminal.cursor;
    let mut saw_red = recovery_bytes(&first.recovery)
        .windows(3)
        .any(|bytes| bytes == b"red");
    while !saw_red {
        if let ServerBody::Output {
            terminal_id,
            cursor: next_cursor,
            data,
        } = client.read_message().body
        {
            if terminal_id == terminal.id && data.windows(3).any(|bytes| bytes == b"red") {
                cursor = next_cursor;
                saw_red = true;
            }
        }
        assert!(
            Instant::now() < deadline,
            "styled PTY output did not arrive"
        );
    }
    assert!(cursor > 0);

    let snapshot = client.attach(&terminal.id, None).recovery;
    let Recovery::Snapshot {
        format,
        scope,
        snapshot_version,
        data,
        ..
    } = snapshot
    else {
        panic!("attach without cursor must return a canonical snapshot");
    };
    assert_eq!(format, "ansi_replay");
    assert_eq!(scope, "viewport");
    assert_eq!(snapshot_version, 1);
    let mut parser = vt100::Parser::new(24, 80, 0);
    parser.process(&data);
    assert!(parser.screen().contents().contains("red"));
    assert_eq!(
        parser.screen().cell(0, 0).unwrap().fgcolor(),
        vt100::Color::Idx(1)
    );
    assert!(parser.screen().cell(0, 0).unwrap().bold());
}

#[test]
fn create_accepts_full_size_desktop_geometry() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let response = client.request(Command::Create {
        create_nonce: "full-size-desktop".into(),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 30".into()],
        current_directory: None,
        environment: Default::default(),
        columns: 138,
        rows: 44,
    });
    assert!(matches!(
        response.body,
        ServerBody::Reply {
            result: Reply::Created { .. },
            ..
        }
    ));
}

#[test]
fn create_rejects_dimensions_that_cannot_fit_a_canonical_snapshot() {
    let broker = BrokerProcess::start();
    let mut client = TestClient::connect(&broker.socket);
    let response = client.request(Command::Create {
        create_nonce: "oversized-dimensions".into(),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 30".into()],
        current_directory: None,
        environment: Default::default(),
        columns: 1_000,
        rows: 1_000,
    });
    assert_error(response, ErrorCode::InvalidDimensions);
}

#[test]
fn ui_disconnect_does_not_kill_pty_and_reconnect_resumes_output() {
    let broker = BrokerProcess::start();
    assert_eq!(
        fs::metadata(&broker.socket).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let (terminal_id, cursor, generation) = {
        let mut ui = TestClient::connect(&broker.socket);
        let terminal = ui.create(
            "/bin/sh",
            vec![
                "-c".into(),
                "printf before; sleep 0.35; printf after; sleep 30".into(),
            ],
        );
        let attached = ui.attach(&terminal.id, None);
        let mut output = recovery_bytes(&attached.recovery);
        let mut cursor = attached.terminal.cursor;
        let deadline = Instant::now() + Duration::from_secs(3);
        while !output.windows(b"before".len()).any(|v| v == b"before") {
            assert!(
                Instant::now() < deadline,
                "did not receive initial PTY output"
            );
            if let ServerBody::Output {
                terminal_id,
                cursor: next_cursor,
                data,
            } = ui.read_message().body
            {
                if terminal_id == terminal.id {
                    cursor = next_cursor;
                    output.extend(data);
                }
            }
        }
        (terminal.id, cursor, ui.generation)
    }; // the simulated UI process closes every connection here

    thread::sleep(Duration::from_millis(600));
    let mut restarted_ui = TestClient::connect(&broker.socket);
    assert_eq!(
        restarted_ui.generation, generation,
        "broker must outlive UI"
    );
    let listed = restarted_ui.request(Command::List);
    match listed.body {
        ServerBody::Reply {
            result: Reply::Listed { terminals },
            ..
        } => assert!(terminals.iter().any(|t| t.id == terminal_id && t.running)),
        other => panic!("list failed: {other:?}"),
    }
    let resumed = restarted_ui.attach(&terminal_id, Some(cursor));
    let bytes = recovery_bytes(&resumed.recovery);
    assert!(
        bytes.windows(b"after".len()).any(|v| v == b"after"),
        "reconnect did not recover output written while the UI was gone: {:?}",
        String::from_utf8_lossy(&bytes)
    );
}

#[test]
fn stale_generation_and_replaced_input_lease_fail_closed_and_queue_is_bounded() {
    let broker = BrokerProcess::start();
    let mut first = TestClient::connect(&broker.socket);
    let terminal = first.create("/bin/sh", vec!["-c".into(), "sleep 30".into()]);
    let first_authority = first.attach(&terminal.id, None);

    let stale_generation = first.request(Command::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: first.generation.wrapping_add(1),
        input_epoch: first_authority.input_epoch,
        lease_id: first_authority.lease_id.clone(),
        data: b"unsafe".to_vec(),
    });
    assert_error(stale_generation, ErrorCode::StaleGeneration);

    let mut second = TestClient::connect(&broker.socket);
    let current_authority = second.attach(&terminal.id, None);
    assert!(current_authority.input_epoch > first_authority.input_epoch);
    let replaced = first.request(Command::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: first.generation,
        input_epoch: first_authority.input_epoch,
        lease_id: first_authority.lease_id,
        data: b"unsafe".to_vec(),
    });
    assert_error(replaced, ErrorCode::StaleLease);

    let oversized = second.request(Command::Input {
        terminal_id: terminal.id,
        broker_generation: second.generation,
        input_epoch: current_authority.input_epoch,
        lease_id: current_authority.lease_id,
        data: vec![b'x'; 64 * 1024 + 1],
    });
    assert_error(oversized, ErrorCode::QueueFull);
}

#[test]
fn terminate_reaps_the_shell_process() {
    let broker = BrokerProcess::start();
    let state = tempfile::tempdir().unwrap();
    let pid_file = state.path().join("shell.pid");
    let survivor_pid_file = state.path().join("survivor.pid");
    let mut client = TestClient::connect(&broker.socket);
    let terminal = client.create(
        "/bin/sh",
        vec![
            "-c".into(),
            "echo $$ > \"$1\"; exec sleep 30".into(),
            "broker-test".into(),
            pid_file.to_string_lossy().into_owned(),
        ],
    );
    let survivor = client.create(
        "/bin/sh",
        vec![
            "-c".into(),
            "echo $$ > \"$1\"; exec sleep 30".into(),
            "broker-test-survivor".into(),
            survivor_pid_file.to_string_lossy().into_owned(),
        ],
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    while !pid_file.exists() || !survivor_pid_file.exists() {
        assert!(Instant::now() < deadline, "shells did not write their pids");
        thread::sleep(Duration::from_millis(10));
    }
    let pid: libc::pid_t = fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let survivor_pid: libc::pid_t = fs::read_to_string(&survivor_pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    let before = client.request(Command::List);
    let running_before = match before.body {
        ServerBody::Reply {
            result: Reply::Listed { terminals },
            ..
        } => terminals.into_iter().filter(|item| item.running).count(),
        other => panic!("list failed: {other:?}"),
    };
    assert_eq!(running_before, 2, "fixture did not start two child PTYs");

    let response = client.request(Command::Terminate {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
    });
    assert!(matches!(
        response.body,
        ServerBody::Reply {
            result: Reply::Accepted,
            ..
        }
    ));
    assert_eq!(
        unsafe { libc::kill(pid, 0) },
        -1,
        "terminate acknowledgement arrived before the process was reaped"
    );
    assert_eq!(
        unsafe { libc::kill(survivor_pid, 0) },
        0,
        "terminating one pane also killed its surviving sibling"
    );

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let message = client.request(Command::List);
        let (running, survivor_running, running_count) = match message.body {
            ServerBody::Reply {
                result: Reply::Listed { terminals },
                ..
            } => {
                let removed_running = terminals
                    .iter()
                    .find(|item| item.id == terminal.id)
                    .unwrap()
                    .running;
                let survivor_running = terminals
                    .iter()
                    .find(|item| item.id == survivor.id)
                    .unwrap()
                    .running;
                let running_count = terminals.iter().filter(|item| item.running).count();
                (removed_running, survivor_running, running_count)
            }
            other => panic!("list failed: {other:?}"),
        };
        if !running {
            assert!(survivor_running, "surviving sibling was not left running");
            assert_eq!(
                running_count, 1,
                "child PTY count did not decrease by exactly one"
            );
            break;
        }
        assert!(Instant::now() < deadline, "shell was not reaped");
        thread::sleep(Duration::from_millis(20));
    }
    let result = unsafe { libc::kill(pid, 0) };
    assert_eq!(result, -1, "terminated shell process still exists");
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );

    let survivor_response = client.request(Command::Terminate {
        terminal_id: survivor.id,
        broker_generation: client.generation,
    });
    assert!(matches!(
        survivor_response.body,
        ServerBody::Reply {
            result: Reply::Accepted,
            ..
        }
    ));
}

#[test]
fn disconnected_terminate_waiter_cannot_acknowledge_a_reused_client_request() {
    let broker = BrokerProcess::start();
    let mut original = TestClient::connect(&broker.socket);
    let terminal = original.create(
        "/bin/sh",
        vec![
            "-c".into(),
            "trap '' HUP TERM; while :; do sleep 1; done".into(),
        ],
    );
    let terminate_id = original.next_id;
    original.next_id += 1;
    serde_json::to_writer(
        &mut original.writer,
        &Request {
            version: PROTOCOL_VERSION,
            id: terminate_id,
            command: Command::Terminate {
                terminal_id: terminal.id,
                broker_generation: original.generation,
            },
        },
    )
    .unwrap();
    original.writer.write_all(b"\n").unwrap();
    original.writer.flush().unwrap();
    drop(original);

    // Give the reactor one turn to observe EOF and release the server-side fd;
    // the next accepted socket normally reuses it. The client incarnation must
    // still prevent the old termination waiter from addressing this request.
    thread::sleep(Duration::from_millis(50));
    let mut replacement = TestClient::connect(&broker.socket);
    replacement.next_id = terminate_id;
    let response = replacement.request(Command::List);
    assert!(matches!(
        response.body,
        ServerBody::Reply {
            result: Reply::Listed { .. },
            ..
        }
    ));
}
