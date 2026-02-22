namespace FLang.Core;

/// <summary>
/// String similarity utilities for "did you mean?" suggestions in diagnostics.
/// </summary>
public static class StringDistance
{
    /// <summary>
    /// Compute the Levenshtein edit distance between two strings.
    /// </summary>
    public static int Levenshtein(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;

        var prev = new int[b.Length + 1];
        var curr = new int[b.Length + 1];

        for (var j = 0; j <= b.Length; j++)
            prev[j] = j;

        for (var i = 1; i <= a.Length; i++)
        {
            curr[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var cost = a[i - 1] == b[j - 1] ? 0 : 1;
                curr[j] = Math.Min(Math.Min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            (prev, curr) = (curr, prev);
        }

        return prev[b.Length];
    }

    /// <summary>
    /// Find the closest match to <paramref name="input"/> from a set of candidates.
    /// Returns null if no candidate is within <paramref name="maxDistance"/>.
    /// </summary>
    public static string? FindClosestMatch(string input, IEnumerable<string> candidates, int maxDistance = 3)
    {
        string? best = null;
        var bestDist = maxDistance + 1;

        foreach (var candidate in candidates)
        {
            // Skip candidates that are too different in length to possibly match
            if (Math.Abs(candidate.Length - input.Length) > maxDistance)
                continue;

            var dist = Levenshtein(input, candidate);
            if (dist < bestDist)
            {
                bestDist = dist;
                best = candidate;
            }
        }

        return best;
    }
}
