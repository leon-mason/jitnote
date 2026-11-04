using LibGit2Sharp;

namespace Jitnote;

/// <summary>
/// Process-wide libgit2 settings. The app must not read the machine's Git config
/// (design.md, product principle: do not change the user's setup to suit the app;
/// same rule as Android GitEnvironment and Mac gn_isolate_config).
/// </summary>
static class GitNative
{
    static readonly object Gate = new();
    static bool ready;

    public static void Initialize()
    {
        lock (Gate)
        {
            if (ready) return;
            // An empty search path, not null: null resets to the default and would see ~/.gitconfig.
            // Levels match libgit2: ProgramData, System, XDG, Global. Local config stays per repository.
            GlobalSettings.SetConfigSearchPaths(ConfigurationLevel.ProgramData);
            GlobalSettings.SetConfigSearchPaths(ConfigurationLevel.System);
            GlobalSettings.SetConfigSearchPaths(ConfigurationLevel.Xdg);
            GlobalSettings.SetConfigSearchPaths(ConfigurationLevel.Global);
            // The Windows build uses the OS certificate store that ships with LibGit2Sharp's win-x64
            // binary. Do not point it at a Mac certificate file. A certificate failure is still reported
            // to the user as 安全证书 (see NotebookGit.Classify).
            ready = true;
        }
    }
}
