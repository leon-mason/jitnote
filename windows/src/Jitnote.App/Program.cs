using Avalonia;

namespace Jitnote;

public static class Program
{
    // The Windows package is built on a Mac and opened on Windows 11. This entry point is the same on both.
    [STAThread]
    public static void Main(string[] args) =>
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
