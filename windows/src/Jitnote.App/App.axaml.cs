using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace Jitnote;

public class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var session = new Session(Session.DefaultDirectory());
            desktop.MainWindow = new MainWindow(session);
            desktop.ShutdownRequested += (_, _) => session.Flush();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
