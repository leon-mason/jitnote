namespace Jitnote;

/// <summary>Who is named on a version this app records. Other tools keep whatever name they already use.</summary>
public sealed record Author(string Name, string Email);

/// <summary>HTTPS credentials. For GitHub and Gitee the password is the personal access token.</summary>
public sealed record Credentials(string Username, string Password);

public enum Side
{
    LOCAL,
    REMOTE,
}

/// <summary>
/// A file both sides changed, or that one side deleted while the other changed.
/// Nothing is merged until the user picks a side. The side that loses stays in history.
/// </summary>
public sealed class PendingConflict : IEquatable<PendingConflict>
{
    public PendingConflict(string path, byte[]? local, byte[]? cloud)
    {
        Path = path;
        Local = local;
        Cloud = cloud;
    }

    public string Path { get; }
    /// <summary>Content on this computer. Null when it was deleted here.</summary>
    public byte[]? Local { get; }
    /// <summary>Content in the cloud. Null when it was deleted there.</summary>
    public byte[]? Cloud { get; }

    public bool Equals(PendingConflict? other) =>
        other != null && Path == other.Path && Same(Local, other.Local) && Same(Cloud, other.Cloud);

    public override bool Equals(object? obj) => Equals(obj as PendingConflict);
    public override int GetHashCode() => Path.GetHashCode(StringComparison.Ordinal);

    static bool Same(byte[]? a, byte[]? b) => a == null ? b == null : b != null && a.AsSpan().SequenceEqual(b);
}

public sealed record SyncResult(bool Pulled, bool Pushed, int Resolved, IReadOnlyList<PendingConflict> Pending);

public sealed record Version(string Commit, long Time, string Message, string Author);

public enum SyncErrorKind
{
    Auth,
    Network,
    NotFound,
    Rejected,
    Other,
}

public sealed class SyncException : Exception
{
    public SyncException(SyncErrorKind kind, string message) : base(message) => Kind = kind;
    public SyncErrorKind Kind { get; }
}
