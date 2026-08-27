// Hangman - terminal word game backed by the system dictionary.
//
// Guess the hidden word one letter at a time. Six misses and you hang.

import std.option
import std.result
import std.string
import std.string_builder
import std.random
import std.time
import std.readline
import std.io.file

const DICT_PATH = "/usr/share/dict/words"
const FALLBACK_WORD = "compiler"
const MAX_MISSES: usize = 6
const MIN_LEN: usize = 5
const MAX_LEN: usize = 9

// =============================================================================
// Word selection
// =============================================================================

// A dictionary line is playable only if it is a plain lowercase a-z word of a guessable length: no
// proper nouns, no apostrophes, no accents.
fn is_playable(w: String) bool {
    if w.len < MIN_LEN or w.len > MAX_LEN {
        return false
    }
    for b in w.bytes() {
        if b < 97 or b > 122 {
            return false
        }
    }
    return true
}

fn count_playable(text: String) usize {
    let n: usize = 0
    for line in text.lines() {
        if is_playable(line) {
            n = n + 1
        }
    }
    return n
}

fn nth_playable(text: String, n: usize) String {
    let i: usize = 0
    for line in text.lines() {
        if is_playable(line) {
            if i == n {
                return line
            }
            i = i + 1
        }
    }
    return FALLBACK_WORD
}

fn pick_word(text: String, rng: &Random) String {
    const total = count_playable(text)
    if total == 0 {
        return FALLBACK_WORD
    }
    return nth_playable(text, rng.next_urange(0, total - 1) as usize)
}

// =============================================================================
// Game state queries
// =============================================================================

fn is_revealed(word: String, tried: String) bool {
    for b in word.bytes() {
        if tried.find(b as char).is_none() {
            return false
        }
    }
    return true
}

// =============================================================================
// Rendering
// =============================================================================

// Row by row, so each body part is a single condition on the miss count.
fn draw_gallows(sb: &StringBuilder, misses: usize, dead: bool) {
    const head = if dead { "X" } else if misses >= 1 { "O" } else { " " }
    const torso = if misses >= 2 { "│" } else { " " }
    const larm = if misses >= 3 { "╱" } else { " " }
    const rarm = if misses >= 4 { "╲" } else { " " }
    const lleg = if misses >= 5 { "╱" } else { " " }
    const rleg = if misses >= 6 { "╲" } else { " " }

    $sb"     ╔════╗\n"
    $sb"     ║    ║\n"
    $sb"     ║    {head}\n"
    $sb"     ║   {larm}{torso}{rarm}\n"
    $sb"     ║   {lleg} {rleg}\n"
    $sb"     ║\n"
    $sb"   ══╩═════\n"
}

fn draw_word(sb: &StringBuilder, word: String, tried: String) {
    for b in word.bytes() {
        if tried.find(b as char).is_some() {
            sb.append(b as char)
        } else {
            $sb"·"

        }
        $sb" "
    }
}

fn draw_pips(sb: &StringBuilder, misses: usize) {
    let i: usize = 0
    while i < MAX_MISSES {
        if i < misses {
            $sb"●"

        } else {
            $sb"○"

        }
        i = i + 1
    }
}

fn draw_screen(word: String, tried: String, misses: usize, dead: bool, reveal: bool) {
    let sb = string_builder(1024)
    defer sb.deinit()

    $sb"\u001b[2J\u001b[H"
    $sb"  ╭──────────────────────────────╮\n"
    $sb"  │  H A N G M A N               │\n"
    $sb"  ╰──────────────────────────────╯\n\n"
    draw_gallows(&sb, misses, dead)
    $sb"\n     "
    if reveal {
        $sb"{word}"

    } else {
        draw_word(&sb, word, tried)
    }
    $sb"\n\n     "
    draw_pips(&sb, misses)
    $sb"   tried: {tried}\n\n"
    print(sb.as_view())
}

// =============================================================================
// Input
// =============================================================================

// The first a-z letter of the line, lowercased; none if the line has none.
fn first_letter(line: String) char? {
    for b in line.bytes() {
        if b >= 65 and b <= 90 {
            return Some((b + 32) as char)
        }
        if b >= 97 and b <= 122 {
            return Some(b as char)
        }
    }
    return null
}

// =============================================================================
// Entry point
// =============================================================================

fn load_dictionary() Result(OwnedString, FileError) {
    const f = open_file(DICT_PATH, FileMode.Read)?
    defer close_file(&f)
    return read_all(&f)
}

pub fn main() i32 {
    let rng = random(monotonic_ns())

    let dict = load_dictionary().ok()
    const word = dict match {
        Some(text) => { pick_word(text.as_view(), &rng) }
        None => { FALLBACK_WORD }
    }

    let tried = string_builder(32)
    defer tried.deinit()
    let misses: usize = 0

    let rl = readline("  guess ▸ ")
    defer rl.deinit()

    loop {
        const won = is_revealed(word, tried.as_view())
        const lost = misses >= MAX_MISSES
        draw_screen(word, tried.as_view(), misses, lost, won or lost)

        if won {
            println("  you win.")
            break
        }
        if lost {
            println($"  dead. the word was: {word}")
            break
        }

        const line = rl.read_line()
        if line.is_none() {
            println("")
            break
        }

        const guess = first_letter(line.unwrap())
        if guess.is_none() {
            continue
        }
        const c = guess.unwrap()

        if tried.as_view().find(c).is_some() {
            continue
        }
        tried.append(c)
        if word.find(c).is_none() {
            misses = misses + 1
        }
    }

    if dict.is_some() {
        dict.unwrap().deinit()
    }
    return 0
}
