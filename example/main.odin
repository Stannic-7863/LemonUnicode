package main

import "core:time"
import "core:unicode/utf8"
import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:os"
import "base:runtime"

import u14 "../"

Test_Context :: struct {
	breaks: [dynamic]bool,
	texts:  [dynamic]u8,
	tests:  [dynamic]Test_Breaks,
}

Test_Breaks :: struct {
	line_number: int,
	text:        string,
	breaks:      []bool,
}

parse_line_break_test :: proc(allocator: runtime.Allocator) -> Test_Context {
	source, err := os.read_entire_file_from_path("./LineBreakTest.txt", allocator)
	if err != nil { panic(fmt.tprintf("%v", err)) }
	defer delete(source, allocator)

	source_text := transmute(string)source

	ctx := Test_Context{}
	ctx.breaks = make([dynamic]bool, allocator)
	ctx.tests  = make([dynamic]Test_Breaks, allocator)
	ctx.texts  = make([dynamic]u8, allocator)

	Temporal_Data :: struct{start_text, end_text, start_break, end_break, line_number: int}
	temporal_data := make([dynamic]Temporal_Data, context.allocator)
	defer delete(temporal_data)

	line_number := 0
	for line in strings.split_lines_iterator(&source_text) {
		line_number += 1
		if len(line) == 0 { continue }
		if strings.starts_with(line, "#") { continue }

		defer free_all(context.temp_allocator)

		data := line
		if tab := strings.index(line, "\t"); tab >= 0 {
			data = line[:tab]
		} else { continue }

		codepoints := make([dynamic]rune, context.temp_allocator)

		breaks_start := len(ctx.breaks)

		for _token in strings.split_iterator(&data, " ") {
			token := strings.trim_space(_token)
			if len(token) == 0 { continue }

			switch token {
			case "×":
				append(&ctx.breaks, false)
			case "÷":
				append(&ctx.breaks, true)
			case:
				codepoint, ok := strconv.parse_int(token, 16)
				if ok { append(&codepoints, rune(codepoint)) }
			}
		}

		breaks_end := len(ctx.breaks)

		if breaks_end - breaks_start > 0 {
			text_start := len(ctx.texts)
			append(&ctx.texts, ..transmute([]u8)utf8.runes_to_string(codepoints[:], context.temp_allocator))
			text_end := len(ctx.texts)
			append(&temporal_data, Temporal_Data{start_break = breaks_start, end_break = breaks_end, start_text = text_start, end_text = text_end, line_number = line_number})
		}
	}

	for t in temporal_data {
		text := ctx.texts[t.start_text:t.end_text]
		breaks := ctx.breaks[t.start_break:t.end_break]
		append(&ctx.tests, Test_Breaks{breaks = breaks, text = string(text), line_number = t.line_number})
	}

	return ctx
}

main :: proc() {
	test := parse_line_break_test(context.allocator)

	not_matched := 0
	for t, i in test.tests {
		breaks := [dynamic]u14.Break_Result{}
		begin := time.now()
		u14.get_line_breaks(t.text, &breaks)
		since := time.since(begin)
		for j in 0..<len(breaks) {
			b_algo := breaks[j]
			b_test := &t.breaks[b_algo.rune_number]

			should_break := b_algo.opportunity == .Mandatory || b_algo.opportunity == .Optional

			if b_test^ != should_break {
				fmt.printfln("#test-no: %i | #line-no: %i \nGot: %v\nExpected: %v\nMismatch at: %i", i, t.line_number, breaks, t.breaks, b_algo.rune_number)
				not_matched += 1
			}

			b_test^ = false
		}

		for b, j in t.breaks { if b { fmt.printfln("#test-no: %i | #line-no: %i \nGot: %v\nExpected: %v\nMismatch at: %i", i, t.line_number, breaks, t.breaks, j) }}
	}

	fmt.println("All tests passed" if not_matched == 0 else "Tests Failed")
}
