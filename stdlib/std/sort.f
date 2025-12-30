
pub fn sort(s: Slice($T)) {
    quick_sort(s)
}

pub fn quick_sort(s: Slice($T)) {
    if s.len <= 1 {
        return
    }
    quick_sort_range(s, 0, s.len - 1)
}

pub fn quick_sort_range(s: Slice($T), lo: usize, hi: usize) {
    if lo >= hi {
        return
    }
    let p := partition_range(s, lo, hi)
    if p > lo {
        quick_sort_range(s, lo, p-1)
    }
    quick_sort_range(s, p+1, hi)
}

fn partition_range(s: Slice($T), lo: usize, hi: usize) -> usize {
    let pivot := s[hi]
    let i = lo
    for (j in lo..hi) {
        if (s[j] <= pivot) {
            swap(&s[i], &s[j])
            i += 1
        }
    }
    swap(&s[i], &s[hi])
    return i
}

fn swap(a: &$T, b: &T) {
    let t := a.*
    a.* = b.*
    b.* = t
}