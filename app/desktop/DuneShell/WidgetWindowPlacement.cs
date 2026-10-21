using System.Drawing;
using System.IO;
using System.Text.Json;

namespace DuneShell;

// Widget geometry is independent of the full management window's state.
internal static class WidgetWindowPlacement
{
    private sealed class SavedBounds
    {
        public int X { get; set; }
        public int Y { get; set; }
        public int W { get; set; }
        public int H { get; set; }
    }

    internal static Rectangle Resolve(Rectangle? saved, Rectangle management)
    {
        // A matching full frame is legacy state, not an intentional compact resize.
        if (saved is Rectangle value && value.Size != management.Size) return value;
        return new Rectangle(management.X, management.Y, 740, 285);
    }

    internal static Rectangle? Load(string path)
    {
        try
        {
            var saved = JsonSerializer.Deserialize<SavedBounds>(File.ReadAllText(path));
            return saved is { W: >= 360, H: >= 240 }
                ? new Rectangle(saved.X, saved.Y, saved.W, saved.H) : null;
        }
        catch { return null; }
    }

    internal static void Save(string path, Rectangle bounds)
    {
        if (bounds.Width < 360 || bounds.Height < 240) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var saved = new SavedBounds { X = bounds.X, Y = bounds.Y, W = bounds.Width, H = bounds.Height };
            File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(saved));
            File.Move(path + ".tmp", path, true);
        }
        catch { /* Window placement is best-effort. */ }
    }
}
