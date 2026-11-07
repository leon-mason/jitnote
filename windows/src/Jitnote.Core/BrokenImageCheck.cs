using System.Text;
using System.Text.RegularExpressions;

namespace Jitnote;

/// <summary>
/// Before a file or folder is moved, finds the notes whose images would no longer be found
/// (design.md「首页」, decision J-13). Reads only; the notes themselves are never rewritten.
///
/// It judges by standard Markdown paths (relative to the note, or "/" from the notebook root) and
/// ignores <see cref="NoteAssets"/>' look-up by file name: the notebook is also opened in Typora,
/// GitHub and other tools, which do not have that fallback. A reference counts only if it pointed
/// at an existing file before the move and points at nothing after it, so moving a folder together
/// with the images its notes use reports nothing.
/// </summary>
public static class BrokenImageCheck
{
    // ![alt](path "title") and ![alt](<path with spaces>); one level of parentheses is allowed inside a bare path.
    static readonly Regex ImageReference = new(@"!\[[^\]\n]*\]\(\s*(?:<([^>\n]*)>|((?:[^\s()]|\([^\s()]*\))*))", RegexOptions.Compiled);
    static readonly Regex Scheme = new("^[a-zA-Z][a-zA-Z0-9+.-]*:", RegexOptions.Compiled);

    /// <summary>
    /// Notebook-relative paths of the notes that would lose an image if <paramref name="source"/> (a file or folder,
    /// notebook-relative) were moved into <paramref name="targetFolder"/> ("" for the root), sorted.
    /// </summary>
    public static IReadOnlyList<string> Notes(string root, string source, string targetFolder)
    {
        var name = source.Split('/').Last();
        var target = targetFolder.Length == 0 ? name : targetFolder + "/" + name;
        if (target == source || target.StartsWith(source + "/", StringComparison.Ordinal)) return Array.Empty<string>();
        var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .Select(file => System.IO.Path.GetRelativePath(root, file).Replace('\\', '/'))
            .Where(path => !path.Split('/').SkipLast(1).Any(part => part.StartsWith(".git", StringComparison.Ordinal)))
            .ToList();
        var before = files.ToHashSet(StringComparer.Ordinal);
        var after = files.Select(path => Moved(path, source, target)).ToHashSet(StringComparer.Ordinal);
        // A single note moved on its own is the only one whose pictures can break (notes do not embed notes),
        // so the rest of a large notebook is not read for it.
        var onlyThis = IsNote(source) && File.Exists(System.IO.Path.Combine(root, source)) ? source : null;
        return files.Where(IsNote).Where(note => onlyThis == null || note == onlyThis).Where(note =>
        {
            var newNote = Moved(note, source, target);
            string text;
            // A note that cannot be read (open in another program, no permission) is skipped: failing here would stop every move.
            try { text = File.ReadAllText(System.IO.Path.Combine(root, note)); }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            return References(text).Any(reference =>
                Resolve(note, reference, before) != null && Resolve(newNote, reference, after) == null);
        }).OrderBy(path => path, StringComparer.Ordinal).ToList();
    }

    static bool IsNote(string path) =>
        path.EndsWith(".md", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".markdown", StringComparison.OrdinalIgnoreCase);

    static string Moved(string path, string source, string target) =>
        path == source || path.StartsWith(source + "/", StringComparison.Ordinal) ? target + path[source.Length..] : path;

    // Image paths written in the text, already without ?query / #anchor and URL-decoded; web addresses are left out.
    static IEnumerable<string> References(string text)
    {
        foreach (Match match in ImageReference.Matches(OutsideCodeBlocks(text)))
        {
            var raw = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            raw = raw.Split('?')[0].Split('#')[0];
            var path = Uri.UnescapeDataString(raw);
            if (path.Length == 0 || path.StartsWith("//", StringComparison.Ordinal) || Scheme.IsMatch(path)) continue;
            yield return path;
        }
    }

    // An image inside a fenced code block is sample text, not an image.
    static string OutsideCodeBlocks(string text)
    {
        string? fence = null;
        var kept = new StringBuilder();
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.TrimStart(' ');
            var marker = trimmed.StartsWith("```", StringComparison.Ordinal) ? "```" : trimmed.StartsWith("~~~", StringComparison.Ordinal) ? "~~~" : null;
            if (fence == null)
            {
                if (marker != null) fence = marker;
                else kept.Append(line).Append('\n');
            }
            else if (marker == fence)
            {
                fence = null;
            }
        }
        return kept.ToString();
    }

    // The notebook-relative file the reference points at from the note, or null when there is none.
    static string? Resolve(string note, string reference, HashSet<string> files)
    {
        var folder = string.Join("/", note.Split('/').SkipLast(1));
        var joined = reference.StartsWith('/') || folder.Length == 0 ? reference : folder + "/" + reference;
        var parts = new List<string>();
        foreach (var part in joined.Split('/'))
        {
            if (part.Length == 0 || part == ".") continue;
            if (part == "..")
            {
                if (parts.Count == 0) return null;
                parts.RemoveAt(parts.Count - 1);
            }
            else
            {
                parts.Add(part);
            }
        }
        var path = string.Join("/", parts);
        return files.Contains(path) ? path : null;
    }
}
