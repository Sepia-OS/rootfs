import base64
import os
import struct
import sys

# The container format busybox loadkmap actually reads (console-tools/loadkmap.c):
#
#   "bkeymap"                     7 bytes of magic, no newline
#   flags[256]                    one byte per keymap table; 1 means "this
#                                 table's 128 entries follow, in order"
#   table x N                     NR_KEYS = 128 entries of uint16, host byte
#                                 order - little-endian on aarch64
#
# Note NR_KEYS is 128, not 256, and that a flagged table is written in full:
# loadkmap calls KDSKBENT for every one of its 128 entries, so whatever is not
# set in it overwrites what the kernel had with whatever was in the file.
BB_MAGIC = b"bkeymap"
NR_KEYS = 128
MAX_NR_KEYMAPS = 256

# A keymap entry is (type << 8) | value.
KT_LATIN = 0x00     # a plain character
KT_LETTER = 0x0b    # a character that CapsLock applies to
K_HOLE = 0x0200     # this key does nothing

# Keys that are functions rather than layout choices. None of the layouts below
# changes them, and the kernel's own keysyms are better than the plain
# character codes the tables give: Enter is K_ENTER (0x0201), not a bare
# carriage return. Left exactly as the kernel had them, which is also what
# makes english_us.kmap byte-identical to the keymap the kernel boots with.
FUNCTION_KEYS = frozenset((1, 14, 15, 28, 57))  # Esc, Backspace, Tab, Enter, Space

# The keymap the kernel starts with, captured from a running SepiaOS with
#   dumpkmap | od -An -tx1 -v
# and kept here so that generated layouts can *change* keys rather than define
# every key from nothing. That distinction is the whole point: a table written
# into a .kmap is loaded in full, so a layout that only knew about the letters
# would silently set Ctrl, both Shifts, Alt, CapsLock, the function keys and
# the cursor keys to NUL - a keyboard that types but cannot be typed on. Every
# key a layout does not mention keeps the value below instead.
#
# To regenerate after a kernel change: boot the image, run the command above on
# the console, and re-encode the bytes with base64.
DEFAULT_KEYMAP = base64.b64decode(
    "YmtleW1hcAEBAQABAQEAAQEBAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAhsAMQAyADMANAA1ADYANwA4ADkA"
    "MAAtAD0AfwAJAHELdwtlC3ILdAt5C3ULaQtvC3ALWwBdAAECAgdhC3MLZAtmC2cLaAtqC2sLbAs7"
    "ACcAYAAAB1wAegt4C2MLdgtiC24LbQssAC4ALwAABwwDAwcgAAcCAAEBAQIBAwEEAQUBBgEHAQgB"
    "CQEIAgkCBwMIAwkDCwMEAwUDBgMKAwEDAgMDAwADEAMGAgACPAAKAQsBAAIAAgACAAIAAgACAAIO"
    "AwIHDQMcAAEHBQIUAQMGGAEBBgIGFwEABhkBFQEWARoBDAENARsBHAEQAREDHQEAAgACAAIAAgAC"
    "AAIAAgACAAIbACEAQAAjACQAJQBeACYAKgAoACkAXwArAH8ACQBRC1cLRQtSC1QLWQtVC0kLTwtQ"
    "C3sAfQABAgIHQQtTC0QLRgtHC0gLSgtLC0wLOgAiAH4AAAd8AFoLWAtDC1YLQgtOC00LPAA+AD8A"
    "AAcMAwMHIAAHAgoBCwEMAQ0BDgEPARABEQESARMBEwIDAgcDCAMJAwsDBAMFAwYDCgMBAwIDAwMA"
    "AxADBgIAAj4ACgELAQACAAIAAgACAAIAAgACDgMCBw0DAAIBBwUCFAEDBgsCAQYCBhcBAAYKAhUB"
    "FgEaAQwBDQEbARwBEAERAx0BAAIAAgACAAIAAgACAAIAAgACAAIAAkAAAAIkAAACAAJ7AFsAXQB9"
    "AFwAAAIAAgACcQt3CxgJcgt0C3kLdQtpC28LcAsAAn4AAQICBxQJcwsXCRkJZwtoC2oLawtsCwAC"
    "AAIAAgAHAAJ6C3gLFgl2CxUJbgttCwACAAIAAgAHDAMDBwACBwIMBQ0FDgUPBRAFEQUSBRMFFAUV"
    "BQgCAgIRCRIJEwkLAw4JDwkQCQoDCwkMCQ0JCgkQAwYCAAJ8ABYFFwUAAgACAAIAAgACAAIAAg4D"
    "AgcNAwACAQcFAhQBAwYYAQEGAgYXAQAGGQEVARYBGgEMAQ0BGwEcARABEQMdAQACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAABsAHAAdAB4AHwB/AAACAAIfAAACCAAAAhEAFwAFABIAFAAZABUACQAPABAA"
    "GwAdAAECAgcBABMABAAGAAcACAAKAAsADAAAAgcAAAAABxwAGgAYAAMAFgACAA4ADQAAAg4CfwAA"
    "BwwDAwcAAAcCAAEBAQIBAwEEAQUBBgEHAQgBCQEIAgQCBwMIAwkDCwMEAwUDBgMKAwEDAgMDAwAD"
    "EAMGAgACAAIKAQsBAAIAAgACAAIAAgACAAIOAwIHDQMcAAEHBQIUAQMGGAEBBgIGFwEABhkBFQEW"
    "ARoBDAENARsBHAEQAREDHQEAAgACAAIAAgACAAIAAgACAAIAAgACAAAAAgACAAIAAgACAAIAAgAC"
    "HwAAAgACAAIRABcABQASABQAGQAVAAkADwAQAAACAAIBAgIHAQATAAQABgAHAAgACgALAAwAAAIA"
    "AgACAAcAAhoAGAADABYAAgAOAA0AAAIAAgACAAcMAwMHAAIHAgACAAIAAgACAAIAAgACAAIAAgAC"
    "CAIAAgcDCAMJAwsDBAMFAwYDCgMBAwIDAwMAAxADBgIAAgACAAIAAgACAAIAAgACAAIAAgACDgMC"
    "Bw0DAAIBBwUCFAEDBhgBAQYCBhcBAAYZARUBFgEaAQwBDQEbARwBEAERAx0BAAIAAgACAAIAAgAC"
    "AAIAAn8CAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAhsIMQgyCDMINAg1CDYINwg4CDkIMAgt"
    "CD0IfwgJCHEIdwhlCHIIdAh5CHUIaQhvCHAIWwhdCA0IAgdhCHMIZAhmCGcIaAhqCGsIbAg7CCcI"
    "YAgAB1wIegh4CGMIdghiCG4IbQgsCC4ILwgABwwDAwcgCAcCAAUBBQIFAwUEBQUFBgUHBQgFCQUI"
    "AgkCBwkICQkJCwMECQUJBgkKAwEJAgkDCQAJEAMGAgACPAgKBQsFAAIAAgACAAIAAgACAAIOAwIH"
    "DQMcAAEHBQIUAQMGGAEQAhECFwEABhkBFQEWARoBDAENARsBHAEQAREDHQEAAgACAAIAAgACAAIA"
    "AgACfwIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAn8CAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIA"
    "AgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAC"
    "AAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAhEIFwgFCBIIFAgZCBUICQgPCBAIAAIA"
    "AgECAgcBCBMIBAgGCAcICAgKCAsIDAgAAgACAAIABwACGggYCAMIFggCCA4IDQgAAgACAAIABwwD"
    "AwcAAgcCAAUBBQIFAwUEBQUFBgUHBQgFCQUIAgACBwMIAwkDCwMEAwUDBgMKAwEDAgMDAwADDAIG"
    "AgACAAIKBQsFAAIAAgACAAIAAgACAAIOAwIHDQMAAgEHBQIUAQMGGAEBBgIGFwEABhkBFQEMAhoB"
    "DAENARsBHAEQAREDHQEAAgACAAIAAgACAAIAAgAC"
)

def make_layout_base():
    """Generates a default, clean baseline standard US-QWERTY mapping."""
    # Standard scancodes for common characters
    scancodes = {
        1: 27,   # Esc
        2: ord('1'), 3: ord('2'), 4: ord('3'), 5: ord('4'), 6: ord('5'),
        7: ord('6'), 8: ord('7'), 9: ord('8'), 10: ord('9'), 11: ord('0'),
        12: ord('-'), 13: ord('='), 14: 127, # Backspace
        15: 9,   # Tab
        16: ord('q'), 17: ord('w'), 18: ord('e'), 19: ord('r'), 20: ord('t'),
        21: ord('y'), 22: ord('u'), 23: ord('i'), 24: ord('o'), 25: ord('p'),
        26: ord('['), 27: ord(']'), 28: 13,  # Enter
        30: ord('a'), 31: ord('s'), 32: ord('d'), 33: ord('f'), 34: ord('g'),
        35: ord('h'), 36: ord('j'), 37: ord('k'), 38: ord('l'), 39: ord(';'),
        40: ord("'"), 41: ord('`'), 43: ord('\\'),
        44: ord('z'), 45: ord('x'), 46: ord('c'), 47: ord('v'), 48: ord('b'),
        49: ord('n'), 50: ord('m'), 51: ord(','), 52: ord('.'), 53: ord('/'),
        57: 32,  # Spacebar
    }

    # Standard uppercase shift configurations
    shifts = {
        2: ord('!'), 3: ord('@'), 4: ord('#'), 5: ord('$'), 6: ord('%'),
        7: ord('^'), 8: ord('&'), 9: ord('*'), 10: ord('('), 11: ord(')'),
        12: ord('_'), 13: ord('+'), 16: ord('Q'), 17: ord('W'), 18: ord('E'),
        19: ord('R'), 20: ord('T'), 21: ord('Y'), 22: ord('U'), 23: ord('I'),
        24: ord('O'), 25: ord('P'), 26: ord('{'), 27: ord('}'), 30: ord('A'),
        31: ord('S'), 32: ord('D'), 33: ord('F'), 34: ord('G'), 35: ord('H'),
        36: ord('J'), 37: ord('K'), 38: ord('L'), 39: ord(':'), 40: ord('"'),
        41: ord('~'), 43: ord('|'),  44: ord('Z'), 45: ord('X'), 46: ord('C'),
        47: ord('V'), 48: ord('B'), 49: ord('N'), 50: ord('M'), 51: ord('<'),
        52: ord('>'), 53: ord('?'),
    }

    # Intialize data sets for all 7 BusyBox modifier slots
    return {
        0: scancodes.copy(),                        # Plain
        1: shifts.copy(),                           # Shift
        2: {}, 3: {}, 4: {}, 5: {}, 6: {}           # AltGr, AltGr+Shift, Ctrl, etc.
    }

# Catalog container for tracking modified system overlays
custom_modifications = {}

# --- 1. ENGLISH UNITED KINGDOM (uk) ---
uk = make_layout_base()
uk[0].update({41: ord('`'), 43: ord('#')})
uk[1].update({3: ord('"'), 4: ord('£'), 40: ord('@'), 41: ord('~'), 43: ord('~')})
custom_modifications["uk"] = uk

# --- 2. GERMAN (de) ---
# The T1 layout, key for key. Two things here were wrong for a long time and
# are worth naming, because both were invisible until somebody typed them:
#
#   - **The comma and full stop keys carry ; and : when shifted**, not < and >.
#     Not stating that left the US values in place, so shift-. gave > and there
#     was no way to type a colon at all - while < and > turned up in a place
#     German does not have them. The real < > | key is scancode 86, next to the
#     left shift, and it was always fine.
#   - **The dead-key pair is acute unshifted, grave shifted**, the way the key
#     is printed. It was the other way round.
de = make_layout_base()
# QWERTZ, the umlauts, and the punctuation German moves.
de[0].update({
    12: ord('ß'), 13: ord('´'), 21: ord('z'), 26: ord('ü'), 27: ord('+'),
    39: ord('ö'), 40: ord('ä'), 41: ord('^'), 43: ord('#'), 44: ord('y'),
    53: ord('-')
})
de[1].update({
    2: ord('!'), 3: ord('"'), 4: ord('§'), 5: ord('$'), 6: ord('%'),
    7: ord('&'), 8: ord('/'), 9: ord('('), 10: ord(')'), 11: ord('='),
    12: ord('?'), 13: ord('`'), 21: ord('Z'), 26: ord('Ü'), 27: ord('*'),
    39: ord('Ö'), 40: ord('Ä'), 41: ord('°'), 43: ord('\''), 44: ord('Y'),
    50: ord('M'), 51: ord(';'), 52: ord(':'), 53: ord('_')
})
# AltGr, where German actually puts it: the braces and brackets on the digits,
# not on the letters above them. Every one of these is stated even where the
# kernel's own AltGr table already agrees, so that the layout describes itself
# rather than depending on what the map underneath happens to hold.
de[2].update({
    3: ord('²'), 4: ord('³'),
    8: ord('{'), 9: ord('['), 10: ord(']'), 11: ord('}'), 12: ord('\\'),
    16: ord('@'),
    18: 8364,  # € - Unicode, so it does not fit a keysym; dropped with a note
    27: ord('~'), 50: ord('µ')
})
custom_modifications["de"] = de

# --- 3. FRENCH (fr) ---
fr = make_layout_base()
# Core AZERTY letter structural updates
fr[0].update({
    16: ord('a'), 17: ord('z'), 21: ord('y'), 30: ord('q'), 44: ord('w'),
    2: ord('à'), 3: ord('é'), 4: ord('\"'), 5: ord('\''), 6: ord('('),
    7: ord('-'), 8: ord('è'), 9: ord('_'), 10: ord('ç'), 11: ord('à'),
    12: ord(')'), 13: ord('='), 26: ord('^'), 27: ord('$'), 39: ord('ù'),
    40: ord('*'), 41: ord('²'), 43: ord('<'), 51: ord(','), 52: ord(';'), 53: ord(':')
})
fr[1].update({
    16: ord('A'), 17: ord('Z'), 21: ord('Y'), 30: ord('Q'), 44: ord('W'),
    2: ord('1'), 3: ord('2'), 4: ord('3'), 5: ord('4'), 6: ord('5'),
    7: ord('6'), 8: ord('7'), 9: ord('8'), 10: ord('9'), 11: ord('0'),
    12: ord('°'), 13: ord('+'), 26: ord('¨'), 27: ord('£'), 39: ord('%'),
    40: ord('µ'), 51: ord('?'), 52: ord('.'), 53: ord('/')
})
fr[2].update({18: 8364, 4: ord('#'), 5: ord('{'), 6: ord('['), 7: ord('|'), 8: ord('`'), 9: ord('\\'), 10: ord('^'), 11: ord('@'), 12: ord(']'), 13: ord('}')})
custom_modifications["fr"] = fr

# Every continental layout below shares one correction with `de`: shift on the
# comma and full-stop keys is ; and :, not the < and > the US map leaves there.
# That is the only thing changed in them - they have not been audited further.

# --- 4. SPANISH (es) ---
es = make_layout_base()
es[0].update({12: ord('\''), 13: ord('¡'), 26: ord('`'), 27: ord('+'), 39: ord('ñ'), 40: ord('´'), 41: ord('º'), 43: ord('ç'), 53: ord('-')})
es[1].update({2: ord('!'), 3: ord('"'), 4: ord('·'), 7: ord('&'), 8: ord('/'), 9: ord('('), 10: ord(')'), 11: ord('='), 12: ord('?'), 13: ord('¿'), 26: ord('^'), 27: ord('*'), 39: ord('Ñ'), 40: ord('¨'), 41: ord('ª'), 43: ord('Ç'), 51: ord(';'), 52: ord(':'), 53: ord('_')})
es[2].update({2: ord('|'), 3: ord('@'), 4: ord('#'), 6: ord('~'), 11: ord('\\'), 26: ord('['), 27: ord(']'), 40: ord('{'), 43: ord('}')})
custom_modifications["es"] = es

# --- 5. ITALIAN (it) ---
it = make_layout_base()
it[0].update({12: ord('\''), 13: ord('ì'), 26: ord('è'), 27: ord('+'), 39: ord('ò'), 40: ord('à'), 41: ord('ì'), 43: ord('ù'), 53: ord('-')})
it[1].update({2: ord('!'), 3: ord('"'), 4: ord('£'), 5: ord('$'), 6: ord('%'), 7: ord('&'), 8: ord('/'), 9: ord('('), 10: ord(')'), 11: ord('='), 12: ord('?'), 13: ord('^'), 26: ord('é'), 27: ord('*'), 39: ord('ç'), 40: ord('°'), 41: ord('§'), 43: ord('§'), 51: ord(';'), 52: ord(':'), 53: ord('_')})
it[2].update({18: 8364, 26: ord('['), 27: ord(']'), 39: ord('@'), 40: ord('#')})
custom_modifications["it"] = it

# --- 6. SWISS (ch) ---
ch = make_layout_base()
ch[0].update({21: ord('z'), 44: ord('y'), 12: ord('\''), 13: ord('^'), 26: ord('ü'), 27: ord('¨'), 39: ord('ö'), 40: ord('ä'), 43: ord('$')})
ch[1].update({21: ord('Z'), 44: ord('Y'), 2: ord('1'), 3: ord('2'), 4: ord('3'), 12: ord('?'), 26: ord('è'), 27: ord('!'), 39: ord('é'), 40: ord('à'), 43: ord('£'), 51: ord(';'), 52: ord(':')})
ch[2].update({3: ord('@'), 4: ord('#'), 18: 8364, 26: ord('['), 27: ord(']'), 39: ord('{'), 40: ord('}')})
custom_modifications["ch"] = ch

# --- 7. NORDIC UNIVERSAL WRAPPER (no / se / fi / dk) ---
nordic = make_layout_base()
nordic[0].update({12: ord('+'), 13: ord('\\'), 26: ord('å'), 27: ord('¨'), 39: ord('ø'), 40: ord('æ'), 41: ord('|'), 43: ord('\'')})
nordic[1].update({2: ord('!'), 3: ord('"'), 4: ord('#'), 5: ord('¤'), 6: ord('%'), 7: ord('&'), 8: ord('/'), 9: ord('('), 10: ord(')'), 11: ord('='), 12: ord('?'), 13: ord('`'), 26: ord('Å'), 27: ord('^'), 39: ord('Ø'), 40: ord('Æ'), 43: ord('*'), 51: ord(';'), 52: ord(':')})
nordic[2].update({3: ord('@'), 5: ord('$'), 8: ord('{'), 9: ord('['), 10: ord(']'), 11: ord('}'), 13: ord('~'), 27: ord('~')})
custom_modifications["nordic"] = nordic

# --- 8. DVORAK ERGONOMIC ---
dvorak = make_layout_base()
dvorak[0].update({
    16: ord('\''), 17: ord(','), 18: ord('.'), 19: ord('p'), 20: ord('y'), 21: ord('f'), 22: ord('g'), 23: ord('c'), 24: ord('r'), 25: ord('l'), 26: ord('/'), 27: ord('='),
    30: ord('a'), 31: ord('o'), 32: ord('e'), 33: ord('u'), 34: ord('i'), 35: ord('d'), 36: ord('h'), 37: ord('t'), 38: ord('n'), 39: ord('s'), 40: ord('-'), 41: ord('\\'),
    44: ord(';'), 45: ord('q'), 46: ord('j'), 47: ord('k'), 48: ord('x'), 49: ord('b'), 50: ord('m'), 51: ord('w'), 52: ord('v'), 53: ord('z')
})
dvorak[1].update({
    16: ord('"'), 17: ord('<'), 18: ord('>'), 19: ord('P'), 20: ord('Y'), 21: ord('F'), 22: ord('G'), 23: ord('C'), 24: ord('R'), 25: ord('L'), 26: ord('?'), 27: ord('+'),
    30: ord('A'), 31: ord('O'), 32: ord('E'), 33: ord('U'), 34: ord('I'), 35: ord('D'), 36: ord('H'), 37: ord('T'), 38: ord('N'), 39: ord('S'), 40: ord('_'), 41: ord('|'),
    44: ord(':'), 45: ord('Q'), 46: ord('J'), 47: ord('K'), 48: ord('X'), 49: ord('B'), 50: ord('M'), 51: ord('W'), 52: ord('V'), 53: ord('Z')
})
custom_modifications["dvorak"] = dvorak

# --- 9. COLEMAK ERGONOMIC ---
colemak = make_layout_base()
colemak[0].update({
    19: ord('p'), 20: ord('g'), 21: ord('j'), 22: ord('l'), 23: ord('u'), 24: ord('y'), 25: ord(';'),
    31: ord('r'), 32: ord('s'), 33: ord('t'), 34: ord('d'), 36: ord('h'), 37: ord('n'), 38: ord('e'), 39: ord('i'), 40: ord('o'),
    49: ord('k')
})
colemak[1].update({
    19: ord('P'), 20: ord('G'), 21: ord('J'), 22: ord('L'), 23: ord('U'), 24: ord('Y'), 25: ord(':'),
    31: ord('R'), 32: ord('S'), 33: ord('T'), 34: ord('D'), 36: ord('H'), 37: ord('N'), 38: ord('E'), 39: ord('I'), 40: ord('O'),
    49: ord('K')
})
custom_modifications["colemak"] = colemak

# --- 10. GERMAN, APPLE KEYBOARD, NO DEAD KEYS (de_mac_nodeadkeys) ---
# xkb calls this de(mac_nodeadkeys). The letters and the digit row are the
# German ones, so it starts from `de`; what Apple moved is the third level,
# because there it is the Option key and the punctuation sits somewhere else
# entirely. @ is Option-L rather than AltGr-Q, the brackets are Option-5/6/8/9
# rather than AltGr-8/9/7/0, the pipe is Option-7 and the backslash is
# Shift-Option-7. On an Apple keyboard the PC German map gets every one of
# those wrong, which is the whole reason this layout exists.
de_mac_nodeadkeys = {mod_layer: keys.copy() for mod_layer, keys in de.items()}

# "No dead keys" needs nothing done here: a console keymap has no dead keys to
# begin with, since KT_LATIN is all this generator emits, and `de` above
# already has the accent key the right way round - acute unshifted, grave
# shifted, the way it is printed.

# The Option level, written out rather than layered onto the German AltGr level
# so that it is exactly what an Apple keyboard produces. Keys not listed keep
# the kernel's own AltGr entries - as in every layout above - so AltGr-8/9/0
# still reach {, [ and ] for anyone who wants them.
#
# Most of the Mac Option level cannot be shown at all: an entry is 16 bits with
# the type in the high byte, so «, ©, ± and the rest of Latin-1 fit, while ∑, †,
# Ω, π, ø-adjacent typography (“ ” ‚ – … • ≠ œ ƒ ∂) does not. Those keys are
# left off rather than listed and dropped one build note at a time.
de_mac_nodeadkeys[2] = {
    2: ord('¡'), 4: ord('¶'), 5: ord('¢'),
    6: ord('['), 7: ord(']'), 8: ord('|'), 9: ord('{'), 10: ord('}'),
    12: ord('¿'),
    16: ord('«'),
    18: 8364,  # € - Option-E, the same key as on the PC layout
    19: ord('®'), 22: ord('¨'), 24: ord('ø'), 27: ord('±'),
    30: ord('å'), 34: ord('©'), 38: ord('@'), 40: ord('æ'),
    46: ord('ç'), 49: ord('~'), 50: ord('µ'),
}

# Shift-Option. The only layout here that reaches past AltGr, and it has to:
# the backslash has no other home on this keyboard.
de_mac_nodeadkeys[3] = {
    8: ord('\\'),
    16: ord('»'), 24: ord('Ø'), 30: ord('Å'), 40: ord('Æ'), 46: ord('Ç'),
}
custom_modifications["de_mac_nodeadkeys"] = de_mac_nodeadkeys


def parse_kmap(blob):
    """Unpacks a binary keymap into {table: [128 keysyms]}."""
    if not blob.startswith(BB_MAGIC):
        raise ValueError("not a binary keymap")
    flags = blob[len(BB_MAGIC):len(BB_MAGIC) + MAX_NR_KEYMAPS]
    body = blob[len(BB_MAGIC) + MAX_NR_KEYMAPS:]
    tables = {}
    for n, table in enumerate(i for i, f in enumerate(flags) if f == 1):
        chunk = body[n * NR_KEYS * 2:(n + 1) * NR_KEYS * 2]
        tables[table] = list(struct.unpack("<%dH" % NR_KEYS, chunk))
    return tables


def keysym(code, name, scancode):
    """Turns a character code from the tables above into a kernel keysym."""
    # An entry is 16 bits with the type in the high byte, so only Latin-1 fits.
    # The euro sign is the one character in these layouts that does not, and
    # dropping it loudly beats writing 0x20ac, whose high byte would be read as
    # keymap type 32 and mean something else entirely.
    if code > 0xFF:
        print(f"    note: {name} scancode {scancode}: U+{code:04X} does not fit "
              f"in a keysym; left unmapped")
        return K_HOLE
    # Letters go in KT_LETTER rather than KT_LATIN so that CapsLock still
    # applies to them - that is exactly what the kernel's own default does.
    if (65 <= code <= 90) or (97 <= code <= 122):
        return (KT_LETTER << 8) | code
    return (KT_LATIN << 8) | code


def compile_binary_kmap(name, matrix, out_dir="."):
    """Writes one layout as a binary keymap busybox loadkmap can read."""
    tables = parse_kmap(DEFAULT_KEYMAP)

    # Only the four tables a layout can change: plain, shift, AltGr and
    # shift+AltGr. The rest of what the kernel had - Ctrl, Alt and their
    # combinations - is carried through untouched.
    #
    # The kernel has no shift+AltGr table at all, so a layout that uses one
    # gets it created here, filled with holes and then given its own entries.
    # That takes nothing away: the combination does nothing today, because an
    # absent table is a keymap the kernel never looks anything up in.
    for mod_layer in (0, 1, 2, 3):
        overrides = matrix.get(mod_layer, {})
        if not overrides:
            continue
        table = tables.setdefault(mod_layer, [K_HOLE] * NR_KEYS)
        for scancode, code in overrides.items():
            if scancode >= NR_KEYS or scancode in FUNCTION_KEYS:
                continue
            table[scancode] = keysym(code, name, scancode)

    # A letter the layout moved but did not give a shifted form: derive it,
    # so that a layout only has to state the interesting half.
    plain, shift = tables[0], tables[1]
    for scancode in range(NR_KEYS):
        if scancode in matrix.get(1, {}):
            continue
        if scancode in matrix.get(0, {}) and 97 <= (plain[scancode] & 0xFF) <= 122:
            shift[scancode] = (KT_LETTER << 8) | ((plain[scancode] & 0xFF) - 32)

    out_filename = os.path.join(out_dir, f"{name}.kmap")
    with open(out_filename, "wb") as f:
        f.write(BB_MAGIC)
        flags = bytearray(MAX_NR_KEYMAPS)
        for table in tables:
            flags[table] = 1
        f.write(bytes(flags))
        for table in sorted(tables):
            f.write(struct.pack("<%dH" % NR_KEYS, *tables[table]))

    print(f" -> Compiled: {out_filename} ({os.path.getsize(out_filename)} bytes)")


# --- MAIN EXECUTION CRADLE ---
if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    print(f"Generating BusyBox binary keymaps into {out_dir}")

    # Process the standard basic English layout
    compile_binary_kmap("english_us", make_layout_base(), out_dir)

    # Loop over and build out all custom maps defined above
    for layout_id, modified_matrix in custom_modifications.items():
        compile_binary_kmap(layout_id, modified_matrix, out_dir)

    print("\nGeneration completed.")