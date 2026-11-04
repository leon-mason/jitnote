using System.Text.Json;

namespace Jitnote;

/// <summary>One JSON file of accounts and notebooks. Tokens never go in here.</summary>
public sealed class StateStore
{
    readonly string path;
    public AppState State { get; private set; }

    public StateStore(string path)
    {
        this.path = path;
        State = File.Exists(path)
            ? JsonSerializer.Deserialize<AppState>(File.ReadAllText(path), AppJson.Options) ?? new AppState()
            : new AppState();
    }

    public void Update(Action<AppState> change)
    {
        change(State);
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        var temp = path + ".sb-" + Guid.NewGuid().ToString("n");
        File.WriteAllText(temp, JsonSerializer.Serialize(State, AppJson.Options));
        File.Move(temp, path, true);
    }
}
