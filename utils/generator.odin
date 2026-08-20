package lemon_unicode

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"

TOTAL_CODEPOINTS :: 0x10FFFF + 1
PAGE_SIZE :: 256
PAGE_COUNT :: (TOTAL_CODEPOINTS + PAGE_SIZE - 1) / PAGE_SIZE

// Which Unicode property table a run of the generator produces. UAX #14 line-break
// data and DerivedGeneralCategory share the same "range ; SHORT_NAME # comment"
// format, so one pipeline covers both — this just picks which defaults to use.
Generation_Kind :: enum {
	Line_Break,
	General_Category,
	East_Asian_Width,
	Emoji_Data,
}

// Where the source ranges come from and what to do with codepoints the file
// doesn't mention.
Page_Generation_Options :: struct {
	source_path:        string, // path to the UCD-style data file, e.g. "./linebreak.txt"
	default_class_name: string, // class assigned to codepoints with no explicit entry
}

// What to call things in the generated .odin file.
File_Generation_Options :: struct {
	kind:              Generation_Kind,
	package_name:      string, // package declaration written into the generated file
	output_path:       string, // where the generated .odin file is written
	type_name:         string, // e.g. "Line_Break_Class"
	prefix:            string,
}

// Everything a build_page_table run produces, bundled up so it can be passed
// around and handed to the file writer as a single value.
Page_Table_Result :: struct {
	class_names:       map[u8]string, // class id -> readable class name, e.g. 3 -> "AL"
	codepoint_classes: [dynamic]u8,   // one class id per codepoint (padded to PAGE_COUNT * PAGE_SIZE)
	unique_pages:      [dynamic]u8,   // deduplicated pages, flattened; PAGE_SIZE entries per page
	page_indices:      [dynamic]u8,   // PAGE_COUNT entries; which unique_pages page each real page maps to
}

Property_Aliases :: struct {
	aliases:  [Generation_Kind]map[string]string,
	prefixes: [Generation_Kind]string,
}

// Sensible defaults for a given kind. Override individual fields after calling
// this if you need something nonstandard (different source path, etc).
generation_default_options :: proc(kind: Generation_Kind) -> (page_options: Page_Generation_Options, file_options: File_Generation_Options) {
	switch kind {
	case .Line_Break:
		page_options = Page_Generation_Options {
			source_path        = "./LineBreak.txt",
			default_class_name = "XX",
		}
		file_options = File_Generation_Options {
			kind         = .Line_Break,
			package_name = "lemon_unicode",
			output_path  = "./generated_line_break.odin",
			type_name    = "Line_Break_Class",
			prefix       = "line_break",
		}
	case .General_Category:
		page_options = Page_Generation_Options {
			source_path        = "./DerivedGeneralCategory.txt",
			default_class_name = "Cn", // "unassigned" in the real UCD data
		}
		file_options = File_Generation_Options {
			kind         = .General_Category,
			package_name = "lemon_unicode",
			output_path  = "./generated_general_category.odin",
			type_name    = "General_Category",
			prefix       = "general_category",
		}
	case .East_Asian_Width:
		page_options = Page_Generation_Options {
			source_path        = "./EastAsianWidth.txt",
			default_class_name = "N",
		}
		file_options = File_Generation_Options {
			kind         = .East_Asian_Width,
			package_name = "lemon_unicode",
			output_path  = "./generated_east_asian_width.odin",
			type_name    = "East_Asian_Width",
			prefix       = "east_asian_width",
		}
	case .Emoji_Data:
		page_options = Page_Generation_Options {
			source_path        = "./emoji-data.txt",
			default_class_name = "No",
		}
		file_options = File_Generation_Options {
			kind             = .Emoji_Data,
			package_name     = "lemon_unicode",
			output_path      = "./generated_emoji_data.odin",
			type_name        = "Emoji",
			prefix           = "emoji",
		}
	}
	return
}

generation_parse_property_aliases :: proc(path: string, allocator: runtime.Allocator) -> (property_aliases: Property_Aliases) {
	property_aliases.prefixes[.Line_Break] = "lb"
	property_aliases.prefixes[.General_Category] = "gc"
	property_aliases.prefixes[.East_Asian_Width] = "ea"

	source_bytes, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		panic(fmt.tprintf("%v", read_error))
	}
	defer delete(source_bytes, allocator)

	source_text := cast(string)source_bytes

	for line in strings.split_lines_iterator(&source_text) {
		if strings.starts_with(line, "#") { continue }
		if len(line) == 0 { continue }

		first_sep := strings.index(line, ";")
		property_type := strings.trim_space(line[:first_sep])

		if !(property_type == "lb" || property_type == "ea" || property_type == "gc") { continue }

		type := Generation_Kind.Line_Break
		for p, e in property_aliases.prefixes {
			if p == property_type {
				type = e
				break
			}
		}

		after_first := line[first_sep + 1:]
		second_sep := strings.index(after_first, ";")
		property_alias := strings.trim_space(after_first[:second_sep])
		after_second := after_first[second_sep + 1:]

		third_sep := strings.index(after_second, ";")
		property_name: string
		if third_sep < 0 { property_name = strings.trim_space(after_second) }
		else { property_name = strings.trim_space(after_second[:third_sep]) }

		if property_type == "lb" {
			if property_name == "E_Modifier" {
				property_name = "Emoji_Modifier"
			}
			if property_name == "E_Base" {
				property_name = "Emoji_Base"
			}
		}

		property_aliases.aliases[type][strings.clone(property_alias, allocator)] = strings.clone(property_name, allocator)
	}

	return property_aliases
}

// Reads a UCD-style range file into one class id per codepoint, plus the
// id -> name table for those classes. Id 0 is always default_class_name.
generation_parse_source_file :: proc(path: string, default_class_name: string, allocator: runtime.Allocator) -> (codepoint_classes: [dynamic]u8, class_names: map[u8]string) {
	source_bytes, read_error := os.read_entire_file_from_path(path, allocator)
	if read_error != nil {
		panic(fmt.tprintf("%v", read_error))
	}
	defer delete(source_bytes, allocator)

	source_text := cast(string)source_bytes

	next_class_id := u8(0)
	class_id_by_name := make(map[string]u8, context.temp_allocator)
	defer delete(class_id_by_name)

	class_names = make(map[u8]string, allocator)
	codepoint_classes = make([dynamic]u8, len = PAGE_COUNT * PAGE_SIZE, allocator = allocator)

	{
		name := strings.clone(default_class_name, allocator)
		class_id_by_name[name] = next_class_id
		class_names[next_class_id] = name
		next_class_id += 1
	}

	for line in strings.split_lines_iterator(&source_text) {
		if strings.starts_with(line, "#") { continue }
		if len(line) == 0 { continue }

		separator_index := strings.index(line, ";")
		if separator_index == -1 { continue }

		comment_index := strings.index(line, "#")
		if comment_index == -1 { comment_index = len(line) }

		range_text := strings.trim_space(line[:separator_index])
		class_name_text := strings.trim_space(line[separator_index + 1:comment_index])

		class_id, found := class_id_by_name[class_name_text]
		if !found {
			name := strings.clone(class_name_text, allocator)
			class_id_by_name[name] = next_class_id
			class_names[next_class_id] = name
			class_id = next_class_id
			next_class_id += 1
		}

		dots_index := strings.index(range_text, "..")

		start_text := range_text
		end_text := range_text

		if dots_index != -1 {
			start_text = range_text[:dots_index]
			end_text = range_text[dots_index + 2:]
		}

		start_codepoint, _ := strconv.parse_i64_of_base(start_text, 16)
		end_codepoint, _ := strconv.parse_i64_of_base(end_text, 16)

		for codepoint in start_codepoint ..= end_codepoint {
			codepoint_classes[codepoint] = class_id
		}
	}

	return
}

// Splits codepoint_classes into PAGE_SIZE-sized pages and deduplicates
// identical pages, returning the deduplicated pages plus, for every real
// page, which deduplicated page holds its data.
generation_build_unique_pages :: proc(codepoint_classes: [dynamic]u8, allocator: runtime.Allocator) -> (unique_pages: [dynamic]u8, page_indices: [dynamic]u8) {
	unique_pages = make([dynamic]u8, allocator = allocator)
	page_indices = make([dynamic]u8, allocator)

	seen_pages := make(map[u64]u8, context.temp_allocator)
	defer delete(seen_pages)

	for page_number in 0 ..< PAGE_COUNT {
		page_start := page_number * PAGE_SIZE
		page_bytes := codepoint_classes[page_start:min(len(codepoint_classes), page_start + PAGE_SIZE)]

		page_hash := hash.fnv64a(page_bytes)

		unique_page_index, already_seen := seen_pages[page_hash]

		if !already_seen {
			unique_page_index = u8(len(unique_pages) / PAGE_SIZE)
			seen_pages[page_hash] = unique_page_index
			append(&unique_pages, ..page_bytes)
		}

		append(&page_indices, unique_page_index)
	}

	return
}

// Parses the source file and builds the deduplicated page table in one call.
generation_build_page_table :: proc(options: Page_Generation_Options, allocator: runtime.Allocator) -> Page_Table_Result {
	codepoint_classes, class_names := generation_parse_source_file(options.source_path, options.default_class_name, allocator)
	unique_pages, page_indices := generation_build_unique_pages(codepoint_classes, allocator)

	return Page_Table_Result {
		class_names       = class_names,
		codepoint_classes = codepoint_classes,
		unique_pages      = unique_pages,
		page_indices      = page_indices,
	}
}

// Sanity check: every codepoint must look up to the same class through the
// paged/deduplicated representation as it has in the flat source table.
generation_verify_page_table :: proc(result: Page_Table_Result) {
	for class_id, codepoint in result.codepoint_classes {
		page_number := codepoint >> intrinsics.count_trailing_zeros(u64(PAGE_SIZE))
		page_offset := codepoint & (PAGE_SIZE - 1)

		unique_page_index := result.page_indices[page_number]
		looked_up_class := result.unique_pages[int(unique_page_index) * PAGE_SIZE + page_offset]

		assert(looked_up_class == class_id)
	}
}

// Renders a Page_Table_Result into the text of a ready-to-compile .odin file.
generation_format_odin_source :: proc(result: Page_Table_Result, options: File_Generation_Options, property_aliases: Property_Aliases, allocator: runtime.Allocator) -> string {
	builder := strings.builder_make(allocator)

	class_ids, _ := slice.map_keys(result.class_names, allocator)
	sort.bubble_sort(class_ids)

	strings.write_string(&builder, "package ")
	strings.write_string(&builder, options.package_name)
	strings.write_string(&builder, "\n\n")

	strings.write_string(&builder, "PAGE_SIZE :: ")
	strings.write_int(&builder, PAGE_SIZE)
	strings.write_string(&builder, "\n")

	strings.write_string(&builder, "PAGE_COUNT :: ")
	strings.write_int(&builder, PAGE_COUNT)
	strings.write_string(&builder, "\n")

	strings.write_string(&builder, "PAGE_SHIFT :: ")
	strings.write_int(&builder, intrinsics.count_trailing_zeros(PAGE_SIZE))
	strings.write_string(&builder, "\n")

	strings.write_string(&builder, "TOTAL_CODEPOINTS :: 0x")
	strings.write_int(&builder, TOTAL_CODEPOINTS, 16)
	strings.write_string(&builder, "\n\n")

	strings.write_string(&builder, options.type_name)
	strings.write_string(&builder, " :: enum u8 {\n")

	for class_id in class_ids {
		class_name := result.class_names[class_id]
		strings.write_string(&builder, "\t")
		strings.write_string(&builder, class_name)
		strings.write_string(&builder, ",\n")
	}
	strings.write_string(&builder, "}\n\n")

	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_pages")
	strings.write_string(&builder, " := []u8{")
	for unique_page_index, i in result.page_indices {
		if i % 20 == 0 {
			strings.write_string(&builder, "\n\t")
		}
		strings.write_u64(&builder, u64(unique_page_index))
		strings.write_string(&builder, ", ")
	}
	strings.write_string(&builder, "\n}\n\n")

	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_table")
	strings.write_string(&builder, " := []")
	strings.write_string(&builder, options.type_name)
	strings.write_string(&builder, "{")
	for class_id, i in result.unique_pages {
		if i % (PAGE_SIZE / 8) == 0 {
			strings.write_string(&builder, "\n\t")
		}
		strings.write_string(&builder, ".")
		strings.write_string(&builder, result.class_names[class_id])
		strings.write_string(&builder, ", ")
	}
	strings.write_string(&builder, "\n}\n\n")

	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_from_rune")
	strings.write_string(&builder, " :: proc(codepoint: rune) -> ")
	strings.write_string(&builder, options.type_name)
	strings.write_string(&builder, " {\n\tpage_number := int(codepoint) >> PAGE_SHIFT\n\tpage_offset := int(codepoint) & (PAGE_SIZE - 1)\n\treturn ")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_table")
	strings.write_string(&builder, "[int(")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_pages")
	strings.write_string(&builder, "[page_number]) * PAGE_SIZE + page_offset]\n}\n\n")

	strings.write_string(&builder, "_is_")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, " :: proc(codepoint: rune, ")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, ": ")
	strings.write_string(&builder, options.type_name)
	strings.write_string(&builder, ") -> bool {\n\treturn ")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "_from_rune(codepoint) == ")
	strings.write_string(&builder, options.prefix)
	strings.write_string(&builder, "\n}\n\n")

	for class_id in class_ids {
		class_name := result.class_names[class_id]
		if options.kind == .Line_Break {
			if class_name == "SOT" || class_name == "EOT" {
				continue
			}
		}
		class_name_full := property_aliases.aliases[options.kind][class_name]
		class_name_full_lower := strings.to_lower(class_name_full, context.temp_allocator) if options.kind != .Emoji_Data else strings.to_lower(class_name, context.temp_allocator)

		strings.write_string(&builder, "is_")
		strings.write_string(&builder, options.prefix)
		strings.write_string(&builder, "_")
		strings.write_string(&builder, class_name_full_lower)
		strings.write_string(&builder, " :: proc(codepoint: rune) -> bool {")
		strings.write_string(&builder, "\n")
		strings.write_string(&builder, "\treturn ")
		strings.write_string(&builder, options.prefix)
		strings.write_string(&builder, "_from_rune(codepoint) == .")
		strings.write_string(&builder, class_name)
		strings.write_string(&builder, "\n}\n\n")
	}

	return strings.to_string(builder)
}

// Formats the result and writes it to options.output_path.
generation_generate_file :: proc(result: Page_Table_Result, options: File_Generation_Options, property_aliases: Property_Aliases, allocator: runtime.Allocator) {
	source := generation_format_odin_source(result, options, property_aliases, allocator)
	fmt.println(source)

	file, open_error := os.open(options.output_path, {.Read, .Write, .Create})
	if open_error != nil {
		panic(fmt.tprintln(open_error))
	}
	defer os.close(file)

	os.write_slice(file, transmute([]u8)source)
}

// Full pipeline for one kind: parse, build, verify, write.
generation_run :: proc(kind: Generation_Kind, property_aliases: Property_Aliases, allocator: runtime.Allocator) {
	page_options, file_options := generation_default_options(kind)

	result := generation_build_page_table(page_options, allocator)

	if file_options.kind == .Emoji_Data {
		for _, &class_name in result.class_names {
			underscore_index := strings.index(class_name, "_")
			if underscore_index == -1 { continue }
			prefix := class_name[:underscore_index]
			if prefix == "Emoji" {
				class_name = class_name[underscore_index+1:]
			}
		}
	}

	if file_options.kind == .Line_Break {
		result.class_names[u8(len(result.class_names))] = "EOT"
		result.class_names[u8(len(result.class_names))] = "SOT"
	}

	generation_verify_page_table(result)
	generation_generate_file(result, file_options, property_aliases, allocator)
}

main :: proc() {
	property_aliases := generation_parse_property_aliases("./PropertyValueAliases.txt", context.allocator)
	generation_run(.Line_Break, property_aliases, context.allocator)
	generation_run(.General_Category, property_aliases, context.allocator)
	generation_run(.East_Asian_Width, property_aliases, context.allocator)
	generation_run(.Emoji_Data, property_aliases, context.allocator)
}
