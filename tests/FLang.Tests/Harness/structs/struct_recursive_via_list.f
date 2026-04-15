//! TEST: struct_recursive_via_list
//! EXIT: 3

// Recursive struct through a generic container (self-hosting pattern: tree nodes)
import std.list

type TreeNode = struct {
    value: i32
    children: List(TreeNode)
}

fn depth(node: &TreeNode) i32 {
    let max_child = 0
    for child in node.children {
        let d = depth(&child)
        if d > max_child {
            max_child = d
        }
    }
    return max_child + 1
}

pub fn main() i32 {
    let leaf1 = TreeNode { value = 1, children = list(0) }
    let leaf2 = TreeNode { value = 2, children = list(0) }

    let mid_children: List(TreeNode) = list(2)
    mid_children.push(leaf1)
    mid_children.push(leaf2)
    let mid = TreeNode { value = 3, children = mid_children }

    let root_children: List(TreeNode) = list(1)
    root_children.push(mid)
    let root = TreeNode { value = 0, children = root_children }

    return depth(&root)
}
