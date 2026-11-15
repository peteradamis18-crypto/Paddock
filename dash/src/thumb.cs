// THUMB (W1-11, docs/rework/cards/W1-11.md): the YouTube thumbnail of a race. One real frame of the race's own video (ffmpeg, at the
// race's best moment: the decisive pass, else the finish line, else the start), 1280 x 720, with big broadcast type in the house gold
// (#C9A24B, design.css --gold): the place change "P15 → P4" or the result "WIN", the track small, Paddock's wordmark small.
// One layout, System.Drawing, the shell's font (Bahnschrift, design.css --font; Segoe UI where it is missing). Never a drawing of a
// car, never stock art (premium: real assets only). A JPEG under YouTube's 2 MB. Make() is pure but for the one ffmpeg run.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;

namespace IRDash
{
    static class Thumb
    {
        public const int W = 1280, H = 720;
        public const long MaxBytes = 2L * 1024 * 1024;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly Color Gold = Color.FromArgb(0xC9, 0xA2, 0x4B);
        // args, timeoutMs -> exit code (Cuts.Yielded = a session started; -1 = timed out). The library points it at the recorder's runner.
        public static Func<string, int, int> Ffmpeg;
        public static string LastArgs = "";

        // the big words: a gain shows the change, a win says WIN, anything else its place, nothing known = no big type
        public static string BigText(Facts f)
        {
            if (f.Finish == 1) return "WIN";
            if (f.Start > 0 && f.Finish > 0 && f.Start > f.Finish) return "P" + f.Start.ToString(Inv) + " → P" + f.Finish.ToString(Inv);
            if (f.Finish > 0) return "P" + f.Finish.ToString(Inv);
            return "";
        }

        // "ok", "YIELD" (a session started: try again after it) or why not. out.jpg is written only when it is complete.
        public static string Make(string ffmpegExe, string video, double atSec, Facts f, string outJpg)
        {
            string frame = outJpg + ".frame.png", part = outJpg + ".part.jpg";
            try
            {
                if (!File.Exists(video)) return "The race video is missing.";
                if (Ffmpeg == null && !File.Exists(ffmpegExe)) return "The video tool is missing.";
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outJpg)));
                TryDelete(frame);
                string args = "-v error -y -ss " + Math.Max(0, atSec).ToString("0.000", Inv) + " -i \"" + video + "\" -frames:v 1" +
                              " -vf \"scale=" + W + ":" + H + ":force_original_aspect_ratio=increase,crop=" + W + ":" + H + "\" \"" + frame + "\"";
                LastArgs = args;
                string err = "";
                int rc = Ffmpeg != null ? Ffmpeg(args, 60000) : Cuts.Exec(ffmpegExe, args, 60000, true, out err);
                if (rc == Cuts.Yielded) { TryDelete(frame); return "YIELD"; }
                if (rc != 0 || !File.Exists(frame)) { TryDelete(frame); return "The race picture could not be taken (ffmpeg " + rc.ToString(Inv) + ")."; }
                using (Bitmap src = new Bitmap(frame))
                using (Bitmap pic = new Bitmap(W, H, PixelFormat.Format24bppRgb))
                {
                    using (Graphics g = Graphics.FromImage(pic))
                    {
                        g.SmoothingMode = SmoothingMode.AntiAlias; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; g.CompositingQuality = CompositingQuality.HighQuality;
                        g.DrawImage(src, new Rectangle(0, 0, W, H));
                        Draw(g, BigText(f), (f.Track ?? "").Trim());
                    }
                    Save(pic, part, 90);
                    if (new FileInfo(part).Length > MaxBytes) Save(pic, part, 75);
                }
                TryDelete(frame);
                if (new FileInfo(part).Length > MaxBytes) { TryDelete(part); return "The thumbnail came out over 2 MB."; }
                TryDelete(outJpg); File.Move(part, outJpg);
                return "ok";
            }
            catch (Exception ex) { TryDelete(frame); TryDelete(part); return "The thumbnail did not work (" + ex.Message + ")."; }
        }

        // the one layout: a dark wash on the left so the type reads on any frame, the big gold words low left, a short gold rule,
        // the track under it, the wordmark top left. Sizes are broadcast sizes for a picture seen at 320 px wide.
        static void Draw(Graphics g, string big, string track)
        {
            using (LinearGradientBrush wash = new LinearGradientBrush(new Rectangle(0, 0, 900, H), Color.FromArgb(225, 0, 0, 0), Color.FromArgb(0, 0, 0, 0), LinearGradientMode.Horizontal))
                g.FillRectangle(wash, 0, 0, 900, H);
            using (LinearGradientBrush low = new LinearGradientBrush(new Rectangle(0, 240, W, H - 240), Color.FromArgb(0, 0, 0, 0), Color.FromArgb(200, 0, 0, 0), LinearGradientMode.Vertical))
                g.FillRectangle(low, 0, 240, W, H - 240);
            string fam = Family();
            using (SolidBrush gold = new SolidBrush(Gold))
            using (SolidBrush white = new SolidBrush(Color.FromArgb(240, 240, 240)))
            using (Font mark = new Font(fam, 30, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                DrawSpaced(g, "PADDOCK", mark, gold, 64, 54, 6);
                float trackTop = 600;
                if (big.Length > 0)
                {
                    // the biggest size that fits 1150 px (a long "P24 → P13" steps down; "WIN" stays huge)
                    float size = 230;
                    Font bf = null; SizeF sz = SizeF.Empty;
                    for (; size >= 90; size -= 10)
                    {
                        if (bf != null) bf.Dispose();
                        bf = new Font(fam, size, FontStyle.Bold, GraphicsUnit.Pixel);
                        sz = g.MeasureString(big, bf, PointF.Empty, StringFormat.GenericTypographic);
                        if (sz.Width <= 1150) break;
                    }
                    using (bf)
                    using (GraphicsPath path = new GraphicsPath())
                    {
                        // a dark outline round the gold: it reads on a bright sky, a yellow kerb or a white car alike
                        float y = 560 - sz.Height;
                        path.AddString(big, bf.FontFamily, (int)FontStyle.Bold, size, new PointF(60, y), StringFormat.GenericTypographic);
                        using (Pen edge = new Pen(Color.FromArgb(200, 0, 0, 0), 12)) { edge.LineJoin = LineJoin.Round; g.DrawPath(edge, path); }
                        g.FillPath(gold, path);
                    }
                    g.FillRectangle(gold, 64, 578, 140, 6);
                }
                else trackTop = 520;
                if (track.Length > 0)
                    using (Font tf = new Font(fam, 54, FontStyle.Regular, GraphicsUnit.Pixel))
                        g.DrawString(Fit(g, track.ToUpperInvariant(), tf, 1100), tf, white, 62, trackTop, StringFormat.GenericTypographic);
            }
        }

        static string Fit(Graphics g, string s, Font f, float w)
        {
            while (s.Length > 3 && g.MeasureString(s, f, PointF.Empty, StringFormat.GenericTypographic).Width > w) s = s.Substring(0, s.Length - 1);
            return s.TrimEnd();
        }

        static void DrawSpaced(Graphics g, string s, Font f, Brush b, float x, float y, float gap)
        {
            foreach (char c in s)
            {
                string one = c.ToString();
                g.DrawString(one, f, b, x, y, StringFormat.GenericTypographic);
                x += g.MeasureString(one, f, PointF.Empty, StringFormat.GenericTypographic).Width + gap;
            }
        }

        static string family;
        public static string Family()
        {
            if (family != null) return family;
            string pick = "Segoe UI";
            try
            {
                using (InstalledFontCollection all = new InstalledFontCollection())
                    foreach (FontFamily ff in all.Families) if (ff.Name == "Bahnschrift") { pick = "Bahnschrift"; break; }
            }
            catch { }
            family = pick;
            return family;
        }

        static void Save(Bitmap b, string path, long quality)
        {
            ImageCodecInfo jpg = null;
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.FormatID == ImageFormat.Jpeg.Guid) jpg = c;
            using (EncoderParameters ps = new EncoderParameters(1))
            {
                ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                b.Save(path, jpg, ps);
            }
        }

        static void TryDelete(string p) { try { if (File.Exists(p)) File.Delete(p); } catch { } }
    }
}
