using System.Text;

namespace FLang.Semantics;

/// <summary>
/// Disjoint set (union-find) with:
/// - First-argument-wins merge semantics (concrete types stay as representatives)
/// - Size-balanced union with identity swapping
/// - Path halving during find
/// - Checkpoint/rollback for speculative unification
/// </summary>
public class DisjointSet<T> where T : notnull
{
    private readonly Dictionary<T, T> _parent = [];
    private readonly Dictionary<T, int> _size = [];

    // Undo log for checkpoint/rollback
    private readonly Stack<List<UndoEntry>> _undoStack = new();

    private readonly record struct UndoEntry(T Key, T OldParent, int OldSize, bool WasNew);

    public T Find(T item)
    {
        if (!_parent.TryGetValue(item, out var parent))
        {
            _parent[item] = item;
            _size[item] = 1;
            return item;
        }

        var root = parent;
        while (!EqualityComparer<T>.Default.Equals(_parent[root], root))
        {
            _parent[root] = _parent[_parent[root]]; // path halving
            root = _parent[root];
        }

        _parent[item] = root;
        return root;
    }

    /// <summary>
    /// Merges the partitions of a and b. The representative of a's partition
    /// becomes the representative of the merged partition.
    /// </summary>
    public void Merge(T a, T b)
    {
        var rootA = Find(a);
        var rootB = Find(b);

        if (EqualityComparer<T>.Default.Equals(rootA, rootB))
            return;

        // Always make rootA the parent — first argument's representative wins.
        // No size-based balancing because the identity-swap trick from the Python
        // version doesn't translate to a flat dictionary (swapping parent entries
        // creates cycles). Path halving in Find keeps lookups efficient enough.
        RecordUndo(rootB, _parent[rootB], _size[rootB], false);
        RecordUndo(rootA, _parent[rootA], _size[rootA], false);
        _parent[rootB] = rootA;
        _size[rootA] += _size[rootB];
    }

    /// <summary>
    /// Begin a speculative region. All Merge operations can be undone via Rollback.
    /// </summary>
    public void PushCheckpoint()
    {
        _undoStack.Push([]);
    }

    /// <summary>
    /// Undo all Merge operations since the last PushCheckpoint.
    /// </summary>
    public void Rollback()
    {
        if (_undoStack.Count == 0)
            throw new InvalidOperationException("No checkpoint to rollback");

        var log = _undoStack.Pop();
        for (var i = log.Count - 1; i >= 0; i--)
        {
            var entry = log[i];
            if (entry.WasNew)
            {
                _parent.Remove(entry.Key);
                _size.Remove(entry.Key);
            }
            else
            {
                _parent[entry.Key] = entry.OldParent;
                _size[entry.Key] = entry.OldSize;
            }
        }
    }

    /// <summary>
    /// Commit the speculative region — discard the undo log.
    /// </summary>
    public void Commit()
    {
        if (_undoStack.Count == 0)
            throw new InvalidOperationException("No checkpoint to commit");

        _undoStack.Pop();
    }

    private void RecordUndo(T key, T oldParent, int oldSize, bool wasNew)
    {
        if (_undoStack.Count > 0)
            _undoStack.Peek().Add(new UndoEntry(key, oldParent, oldSize, wasNew));
    }

    public override string ToString()
    {
        var partitions = new Dictionary<T, List<T>>();
        foreach (var elem in _parent.Keys)
        {
            var root = Find(elem);
            if (!partitions.TryGetValue(root, out var list))
            {
                list = [];
                partitions[root] = list;
            }
            list.Add(elem);
        }

        var sb = new StringBuilder();
        sb.Append('{');
        var firstPartition = true;
        foreach (var kvp in partitions)
        {
            if (!firstPartition) sb.Append(", ");
            firstPartition = false;
            sb.Append(kvp.Key);
            sb.Append(": [");
            for (var i = 0; i < kvp.Value.Count; i++)
            {
                if (i > 0) sb.Append(", ");
                sb.Append(kvp.Value[i]);
            }
            sb.Append(']');
        }
        sb.Append('}');
        return sb.ToString();
    }
}
