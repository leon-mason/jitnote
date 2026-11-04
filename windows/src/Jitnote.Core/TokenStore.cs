using System.Runtime.InteropServices;
using System.Text.Json;

namespace Jitnote;

public interface ITokenStore
{
    void Save(string accountId, string token);
    string? Load(string accountId);
    void Delete(string accountId);
}

/// <summary>
/// Tokens for the Windows build live in the current user's Credential Manager, local to this computer
/// (CRED_PERSIST_LOCAL_MACHINE), not in the notebook and not in the state JSON.
/// On the Mac build machine Credential Manager does not exist, so tests and a local run use
/// <see cref="FileTokenStore"/>, a separate file that is still not the state JSON.
/// </summary>
public static class TokenStores
{
    public static ITokenStore Create(string appDirectory) =>
        OperatingSystem.IsWindows() ? new WindowsCredentialStore() : new FileTokenStore(Path.Combine(appDirectory, "tokens.json"));
}

public sealed class MemoryTokenStore : ITokenStore
{
    readonly Dictionary<string, string> values = new();
    public void Save(string accountId, string token) => values[accountId] = token;
    public string? Load(string accountId) => values.GetValueOrDefault(accountId);
    public void Delete(string accountId) => values.Remove(accountId);
}

public sealed class FileTokenStore : ITokenStore
{
    readonly string path;

    public FileTokenStore(string path) => this.path = path;

    public void Save(string accountId, string token)
    {
        var all = Read();
        all[accountId] = token;
        Write(all);
    }

    public string? Load(string accountId) => Read().GetValueOrDefault(accountId);

    public void Delete(string accountId)
    {
        var all = Read();
        if (!all.Remove(accountId)) return;
        Write(all);
    }

    Dictionary<string, string> Read()
    {
        if (!File.Exists(path)) return new Dictionary<string, string>();
        return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new Dictionary<string, string>();
    }

    void Write(Dictionary<string, string> all)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(path, JsonSerializer.Serialize(all));
    }
}

public sealed class WindowsCredentialStore : ITokenStore
{
    const int CredTypeGeneric = 1;
    // Local to this computer. CRED_PERSIST_ENTERPRISE would roam with the user profile.
    const int CredPersistLocalMachine = 2;

    public void Save(string accountId, string token)
    {
        var bytes = System.Text.Encoding.Unicode.GetBytes(token);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new NativeCredential
            {
                Type = CredTypeGeneric,
                TargetName = Target(accountId),
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                UserName = "Jitnote",
            };
            if (!CredWrite(ref credential, 0))
                throw new InvalidOperationException("没能把授权保存在这台电脑上（" + Marshal.GetLastWin32Error() + "）");
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public string? Load(string accountId)
    {
        if (!CredRead(Target(accountId), CredTypeGeneric, 0, out var pointer)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize <= 0) return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return System.Text.Encoding.Unicode.GetString(bytes);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public void Delete(string accountId) => CredDelete(Target(accountId), CredTypeGeneric, 0);

    static string Target(string accountId) => "Jitnote/" + accountId;

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref NativeCredential credential, int flags);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32")]
    static extern void CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NativeCredential
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
}
