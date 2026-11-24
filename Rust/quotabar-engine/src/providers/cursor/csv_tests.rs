//! Tests for Cursor CSV parser, usage CSV normalization, and spend tiles (`CursorCSVBoundaryTests`, `CursorSpendTests`).

use super::csv::{for_each_record, parse_usage_csv, CursorUsageCSVError, CursorUsageCSVRow, FUTURE_TOLERANCE_SECONDS};
use super::mapper::append_spend_lines;
use crate::context::CancelToken;
use crate::model::{MetricKind, MetricLine, MetricValue};
use crate::pricing::{ModelPricing, TokenBreakdown};

#[test]
fn csv_parser_handles_unicode_escapes_bom_crlf_and_illegal_quotes() {
    let cancel = CancelToken::new();
    let second = format!("second,{},\"\"", "\"".repeat(6));
    let csv = format!("\u{FEFF}Name,Notes,Empty\r\n👩🏽‍💻 café,\"東京, e\u{301}\r\n\"\"quoted\"\"\",\r\n{second}");
    let mut rows = Vec::new();
    let summary = for_each_record(&csv, &cancel, |pairs, _| {
        rows.push(pairs.iter().map(|(k, v)| ((*k).to_string(), v.clone())).collect::<Vec<_>>());
    })
    .unwrap();
    assert!(summary.is_structurally_complete);
    assert_eq!(summary.rejected_record_count, 0);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0][1].1, "東京, e\u{301}\r\n\"quoted\"");
    assert_eq!(rows[1][1].1, "\"\"");

    let mut partial = Vec::new();
    let s2 = for_each_record("Date,Model\n2026-01-01T00:00:00Z,composer-1", &cancel, |p, _| {
        partial.push(p.len());
    })
    .unwrap();
    assert!(s2.is_structurally_complete);
    assert_eq!(partial, vec![2]);

    let cancelled = CancelToken::new();
    cancelled.cancel();
    let s3 = for_each_record(&csv, &cancelled, |_, _| panic!("must not emit")).unwrap();
    assert!(s3.was_cancelled);
    assert!(!s3.is_structurally_complete);

    for bad in [
        "Date,Model\n2026-01-01T00:00:00Z,\"composer-1\"suffix",
        "Date,Model\n2026-01-01T00:00:00Z,com\"poser-1",
        "Date,Model\n2026-01-01T00:00:00Z,\"unterminated",
    ] {
        assert_eq!(for_each_record(bad, &cancel, |_, _| {}), Err(CursorUsageCSVError::MalformedCSV), "{bad}");
    }
}

#[test]
fn usage_csv_validates_grouped_ints_overflow_widths_future_and_bom() {
    let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens";
    let pricing = crate::pricing::shared().current(true);
    let cancel = CancelToken::new();
    let max_ts = 1_800_000_000.0 + FUTURE_TOLERANCE_SECONDS;

    let csv = format!(
        "{header}\n\
        2026-01-01T00:00:00Z,composer-1,,,,\n\
        2026-01-01T00:00:00Z,composer-1,0,\"1,234\",0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,\",\",0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,\"1,2\",0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,\"1,,2\",0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,\"12,34\",0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,-1,0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,1.5,0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,1e3,0,0\n\
        2026-01-01T00:00:00Z,composer-1,0,9223372036854775808,0,0\n"
    );
    let parsed = parse_usage_csv(&csv, &pricing, max_ts, &cancel).unwrap();
    assert_eq!(parsed.rows.iter().map(|r| r.tokens.total_tokens()).collect::<Vec<_>>(), vec![1_234]);
    assert_eq!(parsed.rejected_row_count, 8);

    // Input (w/ Cache Write) and Input (w/o Cache Write) add without subtracting cache read
    let buckets_csv = format!("{header}\n2026-01-01T00:00:00Z,composer-1,10,20,50,5\n");
    let bp_row = &parse_usage_csv(&buckets_csv, &pricing, max_ts, &cancel).unwrap().rows[0];
    assert_eq!(bp_row.tokens.cache_write_5m, 10);
    assert_eq!(bp_row.tokens.input, 20);
    assert_eq!(bp_row.tokens.cache_read, 50);
    assert_eq!(bp_row.tokens.output, 5);

    let overflow_csv = format!("{header}\n2026-01-01T00:00:00Z,composer-1,{},1,0,0\n2026-01-01T00:00:00Z,composer-1,0,100,0,0\n", i64::MAX);
    let ov = parse_usage_csv(&overflow_csv, &pricing, max_ts, &cancel).unwrap();
    assert_eq!(ov.rows.iter().map(|r| r.tokens.total_tokens()).collect::<Vec<_>>(), vec![100]);
    assert_eq!(ov.rejected_row_count, 1);

    let widths = format!("{header}\n2026-01-01T00:00:00Z,composer-1,0,10,0,20\n2026-01-01T00:00:00Z,composer-1,0,10,0,20,\n2026-01-01T00:00:00Z,composer-1,0,10,0\n");
    let wp = parse_usage_csv(&widths, &pricing, max_ts, &cancel).unwrap();
    assert_eq!(wp.rows.len(), 1);
    assert_eq!(wp.rejected_row_count, 2);

    let bom_hdr = "\"\u{FEFF}Date\",\"Model\",\"Input (w/ Cache Write)\",\"Input (w/o Cache Write)\",\"Cache Read\",\"Output Tokens\",Cost\n2026-01-01T00:00:00Z,composer-1,,,,,Included\n";
    let bp = parse_usage_csv(bom_hdr, &pricing, max_ts, &cancel).unwrap();
    assert!(bp.rows.is_empty());
    assert_eq!(bp.rejected_row_count, 0);

    // Future timestamp triggers FutureTimestamp error
    let future_csv = format!("{header}\n2099-01-01T00:00:00Z,composer-1,0,100,0,0\n");
    assert_eq!(parse_usage_csv(&future_csv, &pricing, max_ts, &cancel), Err(CursorUsageCSVError::FutureTimestamp));

    assert_eq!(
        parse_usage_csv("Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read\n", &pricing, max_ts, &cancel),
        Err(CursorUsageCSVError::MissingColumns(vec!["Output Tokens".into()]))
    );
    assert_eq!(
        parse_usage_csv("Date,Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\n", &pricing, max_ts, &cancel),
        Err(CursorUsageCSVError::MalformedCSV)
    );
}

#[test]
fn spend_mapping_reported_dollars_effort_families_and_opaque_grok_bot() {
    let pricing = crate::pricing::shared().current(true);
    let cancel = CancelToken::new();
    let now = 1_800_000_000.0;

    let cost_csv = "\
Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n\
2026-01-01T00:00:00Z,example,0,100,0,1,$1.25\n\
2026-01-01T00:00:01Z,example,0,100,0,1,Included\n\
2026-01-01T00:00:02Z,example,0,100,0,1,$0.00\n\
2026-01-01T00:00:03Z,example,0,0,0,0,$2.50\n\
2026-01-01T00:00:04Z,example,0,100,0,1,EUR 1.50\n";
    let empty_pricing = ModelPricing::default();
    let parsed_costs = parse_usage_csv(cost_csv, &empty_pricing, now, &cancel).unwrap();
    assert_eq!(parsed_costs.rows.iter().map(|r| r.reported_cost_dollars).collect::<Vec<_>>(), vec![Some(1.25), None, Some(0.0), Some(2.50), None]);
    assert!(parsed_costs.rows[3].imputed_cost_dollars.is_none());
    let mut lines = Vec::new();
    let hist = append_spend_lines(&parsed_costs.rows, parsed_costs.rows[0].date, &empty_pricing, &mut lines);
    let rep_dollars: f64 = hist.series.daily.iter().filter_map(|d| d.reported_cost.as_ref().map(|r| r.dollars)).sum();
    let rep_tokens: i64 = hist.series.daily.iter().filter_map(|d| d.reported_cost.as_ref().map(|r| r.covered_tokens)).sum();
    assert!((rep_dollars - 3.75).abs() < 1e-9);
    assert_eq!(rep_tokens, 202);

    // Cursor CSV uses Cursor base rate (no 200k long-context jump) for grok-4.7
    let grok_csv = "Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n2026-01-01T00:00:00Z,grok-4.7,No,0,220000,0,0,Included\n";
    let grok_row = &parse_usage_csv(grok_csv, &pricing, now, &cancel).unwrap().rows[0];
    assert!((grok_row.imputed_cost_dollars.unwrap() - 0.44).abs() < 1e-6);

    // Family grouping: thinking-effort and -fast suffixes group under base family
    let family_rows = vec![
        CursorUsageCSVRow { date: now, model: "claude-opus-4-8-thinking-max".into(), tokens: TokenBreakdown { input: 300, ..Default::default() }, imputed_cost_dollars: Some(3.0), reported_cost_dollars: None, cost_is_opaque_grok_bot: false },
        CursorUsageCSVRow { date: now, model: "claude-opus-4-8-thinking-high".into(), tokens: TokenBreakdown { input: 100, ..Default::default() }, imputed_cost_dollars: Some(1.0), reported_cost_dollars: None, cost_is_opaque_grok_bot: false },
        CursorUsageCSVRow { date: now, model: "gpt-5.5-extra-high-fast".into(), tokens: TokenBreakdown { input: 200, ..Default::default() }, imputed_cost_dollars: Some(2.0), reported_cost_dollars: None, cost_is_opaque_grok_bot: false },
        CursorUsageCSVRow { date: now, model: "gpt-5.5".into(), tokens: TokenBreakdown { input: 50, ..Default::default() }, imputed_cost_dollars: Some(0.5), reported_cost_dollars: None, cost_is_opaque_grok_bot: false },
    ];
    let mut flines = Vec::new();
    let _ = append_spend_lines(&family_rows, now, &pricing, &mut flines);
    let MetricLine::Values { model_breakdown: Some(bd), .. } = flines.iter().find(|l| l.label() == "Today").unwrap() else {
        panic!("expected Today breakdown");
    };
    assert_eq!(bd.models.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(), vec!["claude-opus-4-8", "gpt-5.5"]);
    assert_eq!(bd.models[1].variants.as_ref().unwrap().iter().map(|v| v.model.as_str()).collect::<Vec<_>>(), vec!["gpt-5.5-extra-high-fast", "gpt-5.5"]);

    // Opaque Grok Bot rows fold under "Grok Bot" without raising unknown-model warnings
    let now_iso = crate::time::format_iso8601(now);
    let bot_csv = format!(
        "Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n\
        {now_iso},grok-bot-cua,No,0,100,0,0,Included\n\
        {now_iso},grok-bot-default,No,0,200,0,0,Included\n\
        {now_iso},sand-automation,No,0,300,0,0,Included\n\
        {now_iso},grok-4.7,No,0,50000,0,0,Included\n"
    );
    let bot_parsed = parse_usage_csv(&bot_csv, &pricing, now + 10.0, &cancel).unwrap();
    assert_eq!(bot_parsed.unpriced_grok_bot_row_count, 3);
    let mut bot_lines = Vec::new();
    let bot_hist = append_spend_lines(&bot_parsed.rows, now, &pricing, &mut bot_lines);
    assert_eq!(bot_hist.series.daily[0].total_tokens, 50_600);
    assert!(!bot_hist.series.daily[0].cost_is_complete);
    assert_eq!(bot_hist.series.daily[0].has_unexplained_incomplete_cost, Some(false));
    assert!(bot_hist.unknown_models_by_day.values().all(|s| s.is_empty()));
    let today = bot_lines.iter().find(|l| l.label() == "Today").unwrap();
    assert!(matches!(today, MetricLine::Values { values, unknown_models, .. }
        if unknown_models.is_empty()
            && values.iter().any(|v| matches!(v, MetricValue { kind: MetricKind::Dollars, estimated: true, is_lower_bound: Some(true), .. }))
            && values.iter().any(|v| matches!(v, MetricValue { kind: MetricKind::Count, number, .. } if *number == 50_600.0))
    ));
}
