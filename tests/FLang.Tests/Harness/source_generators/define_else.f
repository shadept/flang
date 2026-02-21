//! TEST: define_else
//! EXIT: 0

// Test #else and #else #if (elif) chaining in source generators.

#define(make_classifier, Name: Ident, N: Ident) {
    fn #(Name)(x: i32) i32 {
        #if N == "three" {
            return 3
        } #else #if N == "two" {
            return 2
        } #else {
            return 1
        }
    }
}

#make_classifier(classify_three, three)
#make_classifier(classify_two, two)
#make_classifier(classify_other, other)

#define(make_sign, Name: Ident) {
    fn #(Name)(x: i32) i32 {
        #if Name == "positive" {
            return 1
        } #else {
            return 0
        }
    }
}

#make_sign(positive)
#make_sign(negative)

pub fn main() i32 {
    if classify_three(0) != 3 { return 1 }
    if classify_two(0) != 2 { return 2 }
    if classify_other(0) != 1 { return 3 }

    if positive(0) != 1 { return 4 }
    if negative(0) != 0 { return 5 }

    return 0
}
