package lemon_unicode

import "base:runtime"
import "core:unicode/utf8"

/*

Rolling Context Approach:


*/

Line_Break_Classes :: bit_set[Line_Break_Class]

Break_Opportunity :: enum {
	Mandatory,
	Optional,
	No_Break,
}

Rule_Context :: struct {
	prev_rune_non_space:      rune `fmt:"X"`,
	prev_prev_rune:           rune `fmt:"X"`,
	prev_rune:                rune `fmt:"X"`,
	curr_rune:                rune `fmt:"X"`,
	next_rune:                rune `fmt:"X"`,
	next_next_rune:           rune `fmt:"X"`,
	prev_non_is_sy:           Line_Break_Class,
	prev_prev_non_is_sy:      Line_Break_Class,
	prev_non_space_prev:      Line_Break_Class,
	prev_non_space:           Line_Break_Class,
	prev_prev:                Line_Break_Class,
	prev:                     Line_Break_Class,
	curr:                     Line_Break_Class,
	next:                     Line_Break_Class,
	next_next:                Line_Break_Class,
	regional_indicator_run:   int, // Need for rule LB30a
	cm_zwj_run:               bool,
	curr_offset:              int,
	next_offset:              int,
	next_next_offset:         int,
	rune_number:              int, // number of rune/codepoints processed so far
}

rule_lb_1 :: proc(ctx: ^Rule_Context) {
	// LB1: Resolving classes
	if ctx.next_next == .AI || ctx.next_next == .SG || ctx.next_next == .XX {
		ctx.next_next = .AL
	}
	if ctx.next_next == .SA {
		general_category := general_category_from_rune(ctx.next_next_rune)
		if general_category == .Mn || general_category == .Mc {
			ctx.next_next = .CM
		} else {
			ctx.next_next = .AL
		}
	}
	if ctx.next_next == .CJ {
		ctx.next_next = .NS
	}
}

rule_lb_2 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB2: Never break at the start of text.
	if ctx.prev == .SOT { return .No_Break, true }
	return .No_Break, false
}

rule_lb_3 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB3: Always break at the end of text.
	if ctx.curr == .EOT { return .Mandatory, true }
	return .No_Break, false
}

rule_lb_4 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB4: Always break at hard line breaks
	if ctx.prev == .BK {
		return .Mandatory, true
	}

	return .No_Break, false
}

rule_lb_5 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB5: CR + LF, LF, CR, NL produce breaks
	// Never break between CR and LF
	if (ctx.prev == .CR) && (ctx.curr == .LF) {
		return .No_Break, true
	}

	rule_lb_5_set :: Line_Break_Classes{.LF, .CR, .NL}

	if ctx.prev in rule_lb_5_set {
		return .Mandatory, true
	}

	return .No_Break, false
}

rule_lb_6 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB6: never break before hard line breaks.
	rule_lb_6_set :: Line_Break_Classes{.BK, .CR, .LF, .NL}
	if ctx.curr in rule_lb_6_set {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_7 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB7: Don't break before Zero width space or space.
	rule_lb_7_set :: Line_Break_Classes{.ZW, .SP}
	if ctx.curr in rule_lb_7_set {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_8 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB8: Break before a character if its followed by zero width space even if there are 1 or more spaces between ZWJ and character
	if (ctx.prev_non_space == .ZW) {
		return .Optional, true
	}

	return .No_Break, false
}

rule_lb_8a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB8a: Never break after a zero width joiner
	if ctx.prev == .ZWJ {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_9 :: proc(ctx: ^Rule_Context, text: string) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB9: Convert CM or ZWJ to base class
	rule_lb_9_set_a :: Line_Break_Classes{.BK, .CR, .LF, .NL, .SP, .ZW}
	rule_lb_9_set_b :: Line_Break_Classes{.CM, .ZWJ}

	if ctx.prev in rule_lb_9_set_a { return .No_Break, false }
	if ctx.curr not_in rule_lb_9_set_b { return .No_Break, false }

	ctx.cm_zwj_run = true
	ctx.curr_rune = ctx.next_rune
	ctx.curr = ctx.next

	return .No_Break, true
}

rule_lb_10 :: proc(ctx: ^Rule_Context, text: string) {
	// LB10: Treat leftovers from lb9 as 'A'
	rule_lb_10_set :: Line_Break_Classes{.CM, .ZWJ}

	if ctx.prev not_in rule_lb_10_set { return }

	ctx.prev_rune = 'A'
	ctx.prev = .AL
}

rule_lb_11 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB11: Don't break before or after Word joiner
	if (ctx.prev == .WJ || ctx.curr == .WJ) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_12 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB12: Don't break after the GL class
	if (ctx.prev == .GL) {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

// Tailorable rules from here now

rule_lb_12a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb12a: Do not break before GL class unless prev class is SP or BA or HY or HH
	rule_lb_12a_set :: Line_Break_Classes{.SP, .BA, .HY, .HH}
	if ctx.prev not_in rule_lb_12a_set && ctx.curr == .GL {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_13 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb13: Do not break before or after ] ! /, even if spaces are present
	rule_lb_13_set :: Line_Break_Classes{.CL, .CP, .EX, .SY}
	if ctx.curr in rule_lb_13_set {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_14 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb14: Do not break after [, even if there are spaces present
	if (ctx.prev_non_space == .OP && ctx.curr != .SP) {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_15a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB15a: Do not break after an unresolved initial punctuation that lies at the start of the line,
	// after a space, after opening punctuation, or after an unresolved quotation mark, even after spaces.
	rule_lb_15a_set :: Line_Break_Classes{.SOT, .BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW}
	if ctx.prev_non_space_prev in rule_lb_15a_set && (general_category_from_rune(ctx.prev_rune_non_space) == .Pi && ctx.prev_non_space == .QU) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_15b :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB15b: Do not break before an unresolved final punctuation that lies at the end of the line,
	// before a space, before a prohibited break, or before an unresolved quotation mark, even after spaces.
	rule_lb_15b_set :: Line_Break_Classes{.SP, .GL, .WJ, .CL, .QU, .CP, .EX, .IS, .SY, .BK, .CR, .LF, .NL, .ZW, .EOT}
	if (general_category_from_rune(ctx.curr_rune) == .Pf && ctx.curr == .QU) && ctx.next in rule_lb_15b_set {
		// prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_15c :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB15c: Break before a decimal mark that follows a space, for instance, in ‘subtract .5’.
	if ctx.prev == .SP && ctx.curr == .IS && ctx.next == .NU {
		return .Optional, true
	}

	return .No_Break, false
}

rule_lb_15d :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB15d: do not break before ‘;’, ‘,’, or ‘.’, even after spaces.
	if (ctx.curr == .IS) {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_16 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb16: Do not break betweeen Closing punctuation and Non-Starter (NS) even if spaces are present
	// Non-Starter: Characters which cannot be on the beginning of a line
	rule_lb_16_set :: Line_Break_Classes{.CL, .CP}
	if ctx.prev_non_space in rule_lb_16_set && ctx.curr == .NS {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_17 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb17: Do not break between —— even if spaces.
	if ctx.prev_non_space == .B2 && ctx.curr == .B2 {
		// prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_18 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb18: Can break after spaces
	if ctx.prev == .SP {
		return .Optional, true
	}

	return .No_Break, false
}

rule_lb_19 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb19: Prevent breaks between unresolved (general category other than pi pf) opening or closing quotations
	if (ctx.curr == .QU && general_category_from_rune(ctx.curr_rune) != .Pi) ||
	 (ctx.prev == .QU && general_category_from_rune(ctx.prev_rune) != .Pf) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_19a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB19a: Unless surrounded by East Asian characters,
	// do not break either side of any unresolved quotation marks.

	east_asian_set :: bit_set[East_Asian_Width]{.F, .W, .H}

	prev_prev_ea := east_asian_width_from_rune(ctx.prev_prev_rune) in east_asian_set
	prev_ea      := east_asian_width_from_rune(ctx.prev_rune) in east_asian_set
	curr_ea      := east_asian_width_from_rune(ctx.curr_rune) in east_asian_set
	next_ea      := east_asian_width_from_rune(ctx.next_rune) in east_asian_set

	r1 := !prev_ea && ctx.curr == .QU
	r2 := ctx.curr == .QU && (!next_ea || ctx.next == .EOT)
	r3 := ctx.prev == .QU && !curr_ea
	r4 := (ctx.prev_prev == .SOT || !prev_prev_ea) && ctx.prev == .QU

	if r1 | r2 | r3 | r4 {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_20 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb20: Break after unresolved CB
	// CB: Contingent Break Opportunity
	if ctx.prev == .CB || ctx.curr == .CB {
		// break
		return .Optional, true
	}

	return .No_Break, false
}

rule_lb_20a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB20a: Do not break after a word-initial hyphen.
	rule_lb_20a_set_a :: Line_Break_Classes{.SOT, .BK, .CR, .LF, .NL, .SP, .ZW, .CB, .GL}
	rule_lb_20a_set_b :: Line_Break_Classes{.HY, .HH}
	rule_lb_20a_set_c :: Line_Break_Classes{.AL, .HL}
	if ctx.prev_prev in rule_lb_20a_set_a && ctx.prev in rule_lb_20a_set_b && ctx.curr in rule_lb_20a_set_c {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_21 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB21: Do not break before hyphen-minus, other hyphens, fixed-width spaces, small kana, and other non-starters, or after acute accents.
	rule_lb_21_set :: Line_Break_Classes{.BA, .HH, .HY, .NS}
	if ctx.curr in rule_lb_21_set || ctx.prev == .BB {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_21a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb21: Do not break after the hyphen in Hebrew + Hyphen + non-Hebrew.
	rule_lb_21a_set :: Line_Break_Classes{.HY, .HH}
	if ctx.prev_prev == .HL && ctx.prev in rule_lb_21a_set && ctx.curr != .HL {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_21b :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb21: Do not break between Solidus and hebrew letters
	if ctx.prev == .SY && ctx.curr == .HL {
		// Prevent Break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_22 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb22: Prevent break before ellipses
	if ctx.curr == .IN {
		// Prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_23 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// rule_lb23: Prevent break between digits and letters
	rule_lb_23_set :: Line_Break_Classes{.AL, .HL}
	if (ctx.prev in rule_lb_23_set && ctx.curr == .NU) || (ctx.prev == .NU && ctx.curr in rule_lb_23_set) {
		// prevent break
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_23a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB23a: Do not break between numeric prefixes and ideographs, or between ideographs and numeric postfixes.
	rule_lb_23a_set :: Line_Break_Classes{.ID, .EB, .EM}
	if (ctx.prev == .PR && ctx.curr in rule_lb_23a_set) || (ctx.prev in rule_lb_23a_set && ctx.curr == .PO) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_24 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB24: Do not break between numeric prefix/postfix and letters, or between letters and prefix/postfix.
	rule_lb_24_set_a :: Line_Break_Classes{.PR, .PO}
	rule_lb_24_set_b :: Line_Break_Classes{.AL, .HL}
	if (ctx.curr in rule_lb_24_set_a && ctx.prev in rule_lb_24_set_b) || (ctx.curr in rule_lb_24_set_b && ctx.prev in rule_lb_24_set_a) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_25 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB25: Prevents weird breaks in numbers
	r1 := ctx.prev_prev_non_is_sy == .NU && ctx.prev == .CL && ctx.curr == .PO
	r2 := ctx.prev_prev_non_is_sy == .NU && ctx.prev == .CP && ctx.curr == .PO
	r3 := ctx.prev_prev_non_is_sy == .NU && ctx.prev == .CL && ctx.curr == .PR
	r4 := ctx.prev_prev_non_is_sy == .NU && ctx.prev == .CP && ctx.curr == .PR
	r5 := ctx.prev_non_is_sy == .NU && ctx.curr == .PO
	r6 := ctx.prev_non_is_sy == .NU && ctx.curr == .PR
	r7 := ctx.prev == .PO && ctx.curr == .OP && ctx.next == .NU
	r8 := ctx.prev == .PO && ctx.curr == .OP && ctx.next == .IS && ctx.next_next == .NU
	r9 := ctx.prev == .PO && ctx.curr == .NU
	r10 := ctx.prev == .PR && ctx.curr == .OP && ctx.next == .NU
	r11 := ctx.prev == .PR && ctx.curr == .OP && ctx.next == .IS && ctx.next_next == .NU
	r12 := ctx.prev == .PR && ctx.curr == .NU
	r13 := ctx.prev == .HY && ctx.curr == .NU
	r14 := ctx.prev == .IS && ctx.curr == .NU
	r15 := ctx.prev_non_is_sy == .NU && ctx.curr == .NU
	// r16 := ctx.prev == .SY && ctx.curr == .NU

	if r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 | r9 | r10 | r11 | r12 | r13 | r14 | r15 {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_26 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB26: Do not break a Korean syllable.
	rule_lb_26_set_a :: Line_Break_Classes{.JL, .JV, .H2, .H3}
	rule_lb_26_set_b :: Line_Break_Classes{.JV, .H2}
	rule_lb_27_set_c :: Line_Break_Classes{.JV, .JT}
	rule_lb_27_set_d :: Line_Break_Classes{.JT, .H3}

	if (ctx.prev in rule_lb_26_set_b && ctx.curr in rule_lb_27_set_c) ||
	 (ctx.prev in rule_lb_27_set_d && ctx.curr == .JT) ||
	 (ctx.prev == .JL && ctx.curr in rule_lb_26_set_a) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_27 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB27: Treat a Korean Syllable Block the same as ID.
	rule_lb_27_set :: Line_Break_Classes{.JL, .JV, .JT, .H2, .H3}
	if (ctx.prev in rule_lb_27_set && ctx.curr == .PO) || (ctx.prev == .PR && ctx.curr in rule_lb_27_set) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_28 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB28: Do not break between alphabetics
	rule_lb_28_set :: Line_Break_Classes{.AL, .HL}
	if ctx.prev in rule_lb_28_set && ctx.curr in rule_lb_28_set {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_28a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB28a: Do not break inside the orthographic syllables of Brahmic scripts.
	dotted_circle := rune(0x25CC)
	rule_lb_28a_set_a := Line_Break_Classes{.AK, .AS}
	rule_lb_28a_set_b := Line_Break_Classes{.VF, .VI}

	sub_r_a := ctx.curr_rune == dotted_circle || ctx.curr in rule_lb_28a_set_a
	sub_r_b := ctx.prev_rune == dotted_circle || ctx.prev in rule_lb_28a_set_a
	sub_r_c := ctx.prev_prev_rune == dotted_circle || ctx.prev_prev in rule_lb_28a_set_a
	r1 := ctx.prev == .AP && sub_r_a
	r2 := sub_r_b && ctx.curr in rule_lb_28a_set_b
	r3 := sub_r_c && ctx.prev == .VI && (ctx.curr == .AK || ctx.curr_rune == dotted_circle)
	r4 := sub_r_b && sub_r_a && ctx.next == .VF

	if r1 | r2 | r3 | r4 {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_29 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB29: Do not break between numeric punctuation and alphabetics (“e.g.”)
	rule_lb_29_set :: Line_Break_Classes{.AL, .HL}
	if ctx.prev == .IS && ctx.curr in rule_lb_29_set {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_30 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB30: Do not break between letters, numbers, or ordinary symbols and opening or closing parentheses.
	east_asia_exclusion_set :: bit_set[East_Asian_Width]{.F, .W, .H}
	rule_lb_30_set :: Line_Break_Classes{.AL, .HL, .NU}

	if (ctx.prev in rule_lb_30_set && (ctx.curr == .OP && east_asian_width_from_rune(ctx.curr_rune) not_in east_asia_exclusion_set)) ||
	 ((ctx.prev == .CP && east_asian_width_from_rune(ctx.prev_rune) not_in east_asia_exclusion_set) && ctx.curr in rule_lb_30_set) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_30a :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB30a: In regional Indicator runs, only allow break between even pairs of regional indicators
	if ctx.prev == .RI && ctx.curr == .RI {
		if ctx.regional_indicator_run & 1 == 1 {
			return .Optional, true
		}
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_30b :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB30b: Do not break between emoji base and emoji modifier
	if (ctx.prev == .EB && ctx.curr == .EM) {
		return .No_Break, true
	}

	general_category := general_category_from_rune(ctx.prev_rune)
	emoji := emoji_from_rune(ctx.prev_rune)

	if (emoji == .Extended_Pictographic && general_category == .Cn) && (ctx.curr == .EM) {
		return .No_Break, true
	}

	return .No_Break, false
}

rule_lb_31 :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	// LB31: Break everywhere if no rule match
	return .Optional, true
}

// Ancient code which was used to debug stuff. Keeping it here as a relic of past
// LB_Rule :: enum u8 {
// 	LB2, LB3, LB4, LB5, LB6, LB7, LB8, LB8a, LB9, LB10,
// 	LB11, LB12, LB12a, LB13, LB14,
// 	LB15a, LB15b, LB15c, LB15d,
// 	LB16, LB17, LB18, LB19, LB19a,
// 	LB20, LB20a, LB21, LB21a, LB21b,
// 	LB22, LB23, LB23a, LB24, LB25,
// 	LB26, LB27, LB28, LB28a, LB29,
// 	LB30, LB30a, LB30b, LB31,
// }

Break_Result :: struct {
    byte_offset: int,
    rune_number: int,
    opportunity: Break_Opportunity,
}

init_context :: proc(text: string) -> Rule_Context {
	ctx := Rule_Context{}
	ctx.prev = .SOT
	ctx.curr = .SOT
	ctx.prev_non_space = .SOT
	ctx.prev_non_space_prev = .SOT
	ctx.prev_prev_non_is_sy = .SOT
	ctx.prev_non_is_sy = .SOT
	ctx.curr = .SOT
	ctx.next = .SOT
	ctx.next_next = .SOT

	ctx.next_next_rune, _ = utf8.decode_rune_in_string(text)
	ctx.next_next = line_break_from_rune(ctx.next_next_rune)

	rule_lb_1(&ctx)
	roll_context(&ctx, text)
	rule_lb_1(&ctx)

	ctx.rune_number = 0
	return ctx
}

roll_context :: proc(ctx: ^Rule_Context, text: string) {
	// Special rule lb 9 handling
	// According to rule lb 9 we need to treat sequence of (CM|ZWJ) as prev. Treat X (CM | ZWJ)* as if it were X.
	// So if we detect a sequence of (ZWJ | CM) we stop rolling over to prev.
	// This has the effect of skip ZWJ|CM runs while applying rule lb1 to lb8 which must be applied before coverting the sequence.
	if !ctx.cm_zwj_run {
		if ctx.prev == .RI {
			ctx.regional_indicator_run += 1
		} else {
			ctx.regional_indicator_run = 0
		}

		if ctx.curr != .SY && ctx.curr != .IS {
			ctx.prev_prev_non_is_sy = ctx.prev_non_is_sy
			ctx.prev_non_is_sy = ctx.curr
		}

		if ctx.curr != .SP {
			ctx.prev_non_space_prev = ctx.prev
			ctx.prev_non_space = ctx.curr
			ctx.prev_rune_non_space = ctx.curr_rune
		}

		ctx.prev_prev_rune = ctx.prev_rune
		ctx.prev_prev = ctx.prev

		ctx.prev_rune = ctx.curr_rune
		ctx.prev = ctx.curr
	}

	ctx.curr_rune = ctx.next_rune
	ctx.curr = ctx.next

	ctx.next = ctx.next_next
	ctx.next_rune = ctx.next_next_rune

	ctx.curr_offset = ctx.next_offset
	ctx.next_offset = ctx.next_next_offset

	ctx.next_next_offset += utf8.rune_size(ctx.next_next_rune)

	if ctx.next_next_offset < len(text) {
		ctx.next_next_rune = utf8.rune_at(text, ctx.next_next_offset)
		ctx.next_next = line_break_from_rune(ctx.next_next_rune)
	} else {
		ctx.next_next = .EOT
		ctx.next_next_rune = 0
	}
}

default_tailorable_rules :: proc(ctx: Rule_Context) -> (opportunity: Break_Opportunity, matched: bool) {
	Line_Break_Rule :: proc(ctx: Rule_Context) -> (Break_Opportunity, bool)

	rules := [?]Line_Break_Rule{
		rule_lb_11, rule_lb_12, rule_lb_12a, rule_lb_13, rule_lb_14, rule_lb_15a, rule_lb_15b, rule_lb_15c, rule_lb_15d,
		rule_lb_16, rule_lb_17, rule_lb_18, rule_lb_19a, rule_lb_19, rule_lb_20, rule_lb_20a, rule_lb_21,rule_lb_21a,
		rule_lb_21b, rule_lb_22, rule_lb_23, rule_lb_23a, rule_lb_24, rule_lb_25, rule_lb_26, rule_lb_27, rule_lb_28,
		rule_lb_28a, rule_lb_29, rule_lb_30, rule_lb_30a, rule_lb_30b, rule_lb_31,
	}

	for rule in rules {
		op, matched := rule(ctx)
		if matched { return op, true }
	}
	return .No_Break, false
}

// Return the total number of breaks written appended
get_line_breaks :: proc(
	text: string,
	results: ^[dynamic]Break_Result,
	tailorable: proc(Rule_Context) -> (Break_Opportunity, bool) = default_tailorable_rules
) -> int {

	match_rule :: proc(ctx: Rule_Context, results: ^[dynamic]Break_Result, opportunity: Break_Opportunity, matched: bool) -> bool {
		if matched && opportunity != .No_Break {
			append(results, Break_Result{byte_offset = ctx.curr_offset, opportunity = opportunity, rune_number = ctx.rune_number})
		}
		return !matched
	}

	if len(text) == 0 { return 0 }
	ctx := init_context(text)

	start := len(results)

	for {
		roll_context(&ctx, text)
		if (ctx.curr == .EOT) { break }
		defer ctx.rune_number += 1
		ctx.cm_zwj_run = false

		// Non Tailorable Rules
		rule_lb_1(&ctx)
		match_rule(ctx, results, rule_lb_2(ctx)) or_continue
		match_rule(ctx, results, rule_lb_4(ctx)) or_continue
		match_rule(ctx, results, rule_lb_5(ctx)) or_continue
		match_rule(ctx, results, rule_lb_6(ctx)) or_continue
		match_rule(ctx, results, rule_lb_7(ctx)) or_continue
		match_rule(ctx, results, rule_lb_8(ctx)) or_continue
		match_rule(ctx, results, rule_lb_8a(ctx)) or_continue
		match_rule(ctx, results, rule_lb_9(&ctx, text)) or_continue
		rule_lb_10(&ctx, text)

		// Tailorable Rules
		match_rule(ctx, results, default_tailorable_rules(ctx)) or_continue

	}

	match_rule(ctx, results, rule_lb_3(ctx))

	return len(results) - start
}
