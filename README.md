[Unicode UAX #14](https://www.unicode.org/reports/tr14/#BreakingRules) line break algorithm implementation.

# Features

- Decently fast.
  - Takes around `100–200 ns per test case` on the [Unicode-provided test suite](https://www.unicode.org/Public/UCD/latest/ucd/auxiliary/LineBreakTest.txt), or roughly `2 ms` to process all ~19,000 test cases. These tests are generally very small, averaging roughly 3–10 runes per case.
  - Takes around `700–800 µs per file` on the [UDHR multilingual text corpus](https://research.ics.aalto.fi/cog/data/udhr/), averaging approximately `60–70 ns per rune`.
  - Overall throughput is roughly `14 million runes per second`.
  - Benchmark configuration:
    - Odin build mode: `-o:speed`
    - Intel(R) Core(TM) i5-4570 CPU @ 3.20GHz
    - 8 GB DDR3 1600 MHz RAM
- State-machine-based implementation.
  - Each line-breaking rule is implemented as its own procedure, making it relatively straightforward to add or modify rules.
- Passes all ~19,000 tests provided by Unicode.

# Usage 
Very straightforward. Call `get_line_breaks` with the input `string` and a pointer to a backing `[dynamic]Break_Result` array. The procedure returns the number of new break results added to the backing array.
```odin

import lu "/LemonUnicode"

text := "A quick brown fox jumps over the lazy dog"

backing := [dynamic]lu.Break_Result{}
breaks_added := lu.get_line_breaks(text, &backing)
```

# Usage of LLM 
- All code is written by me. All implementation/design choices are mine as well.
- Claude was used at some point to refactor `util/generator.odin` to add support for handling all files of same format.
- AI assistance was used to help design the benchmark code and analyze benchmark results.
- Benchmark code for UDHR files is given below.
```odin
	test_files := #load_directory("./udhr/txt")

	benchmark_iterations :: 100

	breaks := [dynamic]u14.Break_Result{}
	append(&breaks, u14.Break_Result{})

	aggregate_time  := time.Duration{}
	aggregate_runes := 0

	minimum := time.MAX_DURATION
	maximum := time.MIN_DURATION

	min_file := ""
	max_file := ""

	for t in test_files {
		text := string(t.data)
		rune_count := utf8.rune_count_in_string(text)

		// Warmup
		for _ in 0..<10 {
			clear(&breaks)
			u14.get_line_breaks(text, &breaks)
		}

		begin := time.now()

		for _ in 0..<benchmark_iterations {
			clear(&breaks)
			u14.get_line_breaks(text, &breaks)
		}

		elapsed := time.since(begin)

    	per_run := elapsed / time.Duration(benchmark_iterations)
    	per_rune := elapsed / time.Duration(benchmark_iterations * rune_count)

		aggregate_time += elapsed
		aggregate_runes += rune_count * benchmark_iterations

		if per_rune < minimum {
			minimum = per_rune
			min_file = t.name
		}

		if per_rune > maximum {
			maximum = per_rune
			max_file = t.name
		}

		fmt.printf(
			"%s\n"+
			"  bytes:       %d\n"+
			"  runes:       %d\n"+
			"  total:       %v\n"+
			"  per run:     %v\n"+
			"  per rune:    %v\n\n",
			t.name, len(text), rune_count, elapsed, per_run, per_rune,
		)
	}

	average_rune := aggregate_time / time.Duration(aggregate_runes)
	total_runs := len(test_files) * benchmark_iterations
	average_run := aggregate_time / time.Duration(total_runs)

	fmt.println("================================")
	fmt.println("TOTAL")
	fmt.printf("  elapsed:      %v\n", aggregate_time)
	fmt.printf("  runs:         %d\n", total_runs)
	fmt.printf("  runes:        %d\n", aggregate_runes)
	fmt.printf("  avg run:      %v\n", average_run)
	fmt.printf("  avg rune:     %v/rune\n", average_rune)
	fmt.printf("  minimum:      %v/rune (%s)\n", minimum, min_file)
	fmt.printf("  maximum:      %v/rune (%s)\n", maximum, max_file)
```
