use ouro_terminal_ghostty::{CompressionStep, Config, MemoryInfo, PageBudget, Terminal};
use std::fmt::Write as _;
use std::io::Write;
use std::time::Duration;
use std::time::Instant;

fn parse_positive_arg(index: usize, default: usize) -> usize {
    std::env::args()
        .nth(index)
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn parse_nonnegative_arg(index: usize, default: usize) -> usize {
    std::env::args()
        .nth(index)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn build_workload(session: usize, lines: usize) -> Vec<u8> {
    let mut payload = String::with_capacity(lines.saturating_mul(72));
    for line in 0..lines {
        writeln!(
            payload,
            "\x1b[3{}mS{session:02} L{line:05} 한글 e\u{301} 🌊 abcdefghijklmnopqrstuvwxyz\x1b[0m\r",
            line % 8
        )
        .expect("write to preallocated workload");
    }
    payload.into_bytes()
}

fn memory_totals(terminals: &[Terminal]) -> (MemoryInfo, usize) {
    let mut totals = MemoryInfo {
        live_bytes: 0,
        peak_bytes: 0,
        limit_bytes: 0,
        allocation_failures: 0,
    };
    let mut maximum_live = 0usize;
    for terminal in terminals {
        let memory = terminal.memory_info().expect("memory accounting");
        assert!(memory.live_bytes <= memory.limit_bytes);
        assert!(memory.peak_bytes <= memory.limit_bytes);
        totals.live_bytes = totals.live_bytes.saturating_add(memory.live_bytes);
        totals.peak_bytes = totals.peak_bytes.saturating_add(memory.peak_bytes);
        totals.limit_bytes = totals.limit_bytes.saturating_add(memory.limit_bytes);
        totals.allocation_failures = totals
            .allocation_failures
            .saturating_add(memory.allocation_failures);
        maximum_live = maximum_live.max(memory.live_bytes);
    }
    (totals, maximum_live)
}

fn snapshot_page_count(snapshot: &[u8]) -> usize {
    const ENVELOPE_BYTES: usize = 10;
    const RECORD_HEADER_BYTES: usize = 10;
    const PAGE_TAG: u16 = 3;
    const FINISH_TAG: u16 = 6;

    assert!(snapshot.len() >= ENVELOPE_BYTES);
    assert_eq!(&snapshot[..8], b"GHOSTSNP");
    assert_eq!(u16::from_le_bytes([snapshot[8], snapshot[9]]), 1);

    let mut offset = ENVELOPE_BYTES;
    let mut pages = 0usize;
    loop {
        assert!(offset.saturating_add(RECORD_HEADER_BYTES) <= snapshot.len());
        let tag = u16::from_le_bytes([snapshot[offset], snapshot[offset + 1]]);
        let payload_bytes = u32::from_le_bytes([
            snapshot[offset + 2],
            snapshot[offset + 3],
            snapshot[offset + 4],
            snapshot[offset + 5],
        ]) as usize;
        offset = offset
            .checked_add(RECORD_HEADER_BYTES)
            .and_then(|value| value.checked_add(payload_bytes))
            .expect("snapshot record length overflow");
        assert!(offset <= snapshot.len());
        if tag == PAGE_TAG {
            pages = pages.saturating_add(1);
        }
        if tag == FINISH_TAG {
            assert_eq!(offset, snapshot.len());
            return pages;
        }
    }
}

fn main() {
    let sessions = parse_positive_arg(1, 32);
    let lines = parse_nonnegative_arg(2, 10_000);
    let scrollback_max_bytes = parse_positive_arg(3, 8 * 1024 * 1024);
    let page_budget_max_bytes = parse_positive_arg(4, 128 * 1024 * 1024);
    let feed_chunk_bytes = parse_positive_arg(5, 16 * 1024);
    let workloads: Vec<Vec<u8>> = (0..sessions)
        .map(|session| build_workload(session, lines))
        .collect();
    let total_input_bytes = workloads
        .iter()
        .fold(0usize, |total, payload| total.saturating_add(payload.len()));
    let total_input_lines = sessions.saturating_mul(lines);
    let page_budget = PageBudget::new(page_budget_max_bytes).expect("shared terminal page budget");
    let started = Instant::now();
    let mut terminals = Vec::with_capacity(sessions);
    let mut total_projection_bytes = 0usize;
    let mut total_retained_markers = 0usize;

    for (session, workload) in workloads.iter().enumerate() {
        let mut terminal = Terminal::new_with_page_budget(
            Config {
                columns: 120,
                rows: 40,
                scrollback_max_bytes,
                scrollback_max_lines: 10_000,
                engine_memory_max_bytes: 16 * 1024 * 1024,
                ..Config::default()
            },
            &page_budget,
        )
        .expect("bounded Ghostty terminal creation");

        for (chunk_index, chunk) in workload.chunks(feed_chunk_bytes).enumerate() {
            if let Err(error) = terminal.feed(chunk) {
                let budget = page_budget
                    .stats()
                    .expect("shared page budget after terminal feed failure");
                panic!(
                    "bounded terminal feed failed: session={session} chunk={chunk_index} \
                     error={error:?} page_reserved={} page_limit={} denials={} child_failures={}",
                    budget.reserved_bytes,
                    budget.limit_bytes,
                    budget.denial_count,
                    budget.child_failure_count
                );
            }
        }
        let projection = terminal
            .plain_text()
            .expect("diagnostic history projection");
        let projection_text = String::from_utf8_lossy(&projection);
        if lines > 0 {
            assert!(projection_text.contains(&format!("S{session:02} L{:05}", lines - 1)));
        }
        let retained_markers = projection_text.matches(&format!("S{session:02} L")).count();
        assert!(
            (lines == 0 && retained_markers == 0)
                || (retained_markers > 0 && retained_markers <= lines)
        );
        total_retained_markers = total_retained_markers.saturating_add(retained_markers);
        total_projection_bytes = total_projection_bytes.saturating_add(projection.len());
        terminals.push(terminal);
    }

    let populate_elapsed = started.elapsed();
    drop(workloads);
    let (before_compression, maximum_live_before_compression) = memory_totals(&terminals);
    let page_budget_before_compression = page_budget
        .stats()
        .expect("shared page budget before compression");
    let mut total_snapshot_bytes = 0usize;
    let mut total_pagelist_pages = 0usize;
    for terminal in &mut terminals {
        let snapshot = terminal.snapshot().expect("canonical page-count snapshot");
        total_snapshot_bytes = total_snapshot_bytes.saturating_add(snapshot.len());
        total_pagelist_pages = total_pagelist_pages.saturating_add(snapshot_page_count(&snapshot));
    }
    let compression_mode =
        std::env::var("OURO_BENCH_COMPRESSION").unwrap_or_else(|_| "none".to_owned());
    let compression_started = Instant::now();
    let mut compression_steps = 0usize;
    let mut compression_unsupported = 0usize;
    match compression_mode.as_str() {
        "none" => {}
        "incremental" => {
            for terminal in &mut terminals {
                let activity = terminal
                    .compression_activity()
                    .expect("compression activity token");
                let mut terminal_steps = 0usize;
                let maximum_terminal_steps = lines.saturating_mul(2).saturating_add(1_024);
                loop {
                    terminal_steps = terminal_steps.saturating_add(1);
                    assert!(
                        terminal_steps <= maximum_terminal_steps,
                        "incremental compression did not converge within benchmark bound"
                    );
                    compression_steps = compression_steps.saturating_add(1);
                    match terminal
                        .compress_incremental_step()
                        .expect("bounded incremental compression step")
                    {
                        CompressionStep::Pending => continue,
                        CompressionStep::Complete => break,
                        CompressionStep::Unsupported => {
                            compression_unsupported = compression_unsupported.saturating_add(1);
                            break;
                        }
                    }
                }
                assert_eq!(
                    terminal
                        .compression_activity()
                        .expect("compression activity token after compression"),
                    activity
                );
            }
        }
        #[cfg(feature = "benchmark-full-compression")]
        "full" => {
            for terminal in &mut terminals {
                compression_steps = compression_steps.saturating_add(1);
                match terminal
                    .compress_full_for_benchmark()
                    .expect("benchmark-only full compression")
                {
                    CompressionStep::Complete => {}
                    CompressionStep::Unsupported => {
                        compression_unsupported = compression_unsupported.saturating_add(1);
                    }
                    CompressionStep::Pending => {
                        panic!("full compression returned a pending continuation")
                    }
                }
            }
        }
        #[cfg(not(feature = "benchmark-full-compression"))]
        "full" => panic!(
            "full mode requires --features benchmark-full-compression; it is disabled by default"
        ),
        other => {
            panic!("unsupported OURO_BENCH_COMPRESSION={other}; use none, incremental, or full")
        }
    }
    let compression_elapsed = compression_started.elapsed();
    let (after_compression, maximum_live_after_compression) = memory_totals(&terminals);
    let page_budget_after_compression = page_budget
        .stats()
        .expect("shared page budget after compression");

    println!("sessions={sessions}");
    println!("lines_per_session={lines}");
    println!("scrollback_max_bytes_per_session={scrollback_max_bytes}");
    println!("feed_chunk_bytes={feed_chunk_bytes}");
    println!("total_input_bytes={total_input_bytes}");
    println!("total_input_lines={total_input_lines}");
    println!(
        "input_bytes_per_line={}",
        if total_input_lines == 0 {
            0
        } else {
            total_input_bytes / total_input_lines
        }
    );
    println!(
        "page_budget_limit_bytes={}",
        page_budget_after_compression.limit_bytes
    );
    println!(
        "page_budget_reserved_before_compression_bytes={}",
        page_budget_before_compression.reserved_bytes
    );
    println!(
        "page_budget_peak_before_compression_bytes={}",
        page_budget_before_compression.peak_reserved_bytes
    );
    println!(
        "page_budget_denials_before_compression={}",
        page_budget_before_compression.denial_count
    );
    println!(
        "page_budget_child_failures_before_compression={}",
        page_budget_before_compression.child_failure_count
    );
    println!(
        "page_budget_reserved_after_compression_bytes={}",
        page_budget_after_compression.reserved_bytes
    );
    println!(
        "page_budget_peak_after_compression_bytes={}",
        page_budget_after_compression.peak_reserved_bytes
    );
    println!(
        "page_budget_denials_after_compression={}",
        page_budget_after_compression.denial_count
    );
    println!(
        "page_budget_child_failures_after_compression={}",
        page_budget_after_compression.child_failure_count
    );
    println!(
        "pre_compression_total_requested_live_bytes={}",
        before_compression.live_bytes
    );
    println!(
        "pre_compression_total_requested_peak_bytes={}",
        before_compression.peak_bytes
    );
    println!("pre_compression_maximum_terminal_live_bytes={maximum_live_before_compression}");
    println!(
        "total_requested_live_bytes={}",
        after_compression.live_bytes
    );
    println!(
        "total_requested_peak_bytes={}",
        after_compression.peak_bytes
    );
    println!("maximum_terminal_live_bytes={maximum_live_after_compression}");
    println!("total_plain_projection_bytes={total_projection_bytes}");
    println!("total_retained_line_markers={total_retained_markers}");
    println!("total_snapshot_bytes={total_snapshot_bytes}");
    println!("total_pagelist_pages={total_pagelist_pages}");
    println!(
        "allocation_failures={}",
        after_compression.allocation_failures
    );
    println!("populate_elapsed_ms={}", populate_elapsed.as_millis());
    println!("compression_mode={compression_mode}");
    println!("compression_steps={compression_steps}");
    println!("compression_unsupported={compression_unsupported}");
    println!("compression_elapsed_ms={}", compression_elapsed.as_millis());
    println!("pid={}", std::process::id());

    if let Some(seconds) = std::env::var("OURO_BENCH_HOLD_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
    {
        std::io::stdout().flush().expect("flush benchmark results");
        std::thread::sleep(Duration::from_secs(seconds));
    }

    std::hint::black_box(&terminals);
    drop(terminals);
    let page_budget_after_drop = page_budget
        .stats()
        .expect("shared page budget after dropping every terminal");
    println!(
        "page_budget_reserved_after_drop_bytes={}",
        page_budget_after_drop.reserved_bytes
    );
    assert_eq!(
        page_budget_after_drop.reserved_bytes, 0,
        "dropping every terminal must return all shared page reservations"
    );
}
