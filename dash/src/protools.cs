// Pro analysis tools (docs\PLAN-v3.md P3): the maths channels and the CSV / Excel export of the analysis workbench.
//   GET /analysis/pro/formulas?car=<car name>                       -> his saved maths channels for that car (JSON)
//   GET /analysis/pro/save?car=&name=&unit=&expr=                   -> save one (the page does this after the formula worked)
//   GET /analysis/pro/delete?car=&name=
//   GET /analysis/pro/maths?id=&lap=&ref=&name=&expr=&unit=         -> the formula on the lap and its reference, the same binary reply as /analysis/channels (PWB1)
//   GET /analysis/pro/export?id=&lap=&ref=&ch=kmh,Gear,@My name&fmt=csv|xlsx&which=both|lap|ref
// A formula is parsed by the small parser below and nothing else: numbers, channel names, + - * / % ^, comparisons, && || !,
// brackets and a fixed list of functions. There is no eval and no way to call anything else. Mistakes come back in plain words.
// Channel names are the ones of the lap file (Speed, Throttle, LatAccel ...), or the derived ones of the workbench picker (kmh,
// latG, slipLR ... same formulas as workbench.js derive()), or [Lateral G] in square brackets when the name has spaces.
// The grid is the one /analysis/channels uses (about 1 m, the last sample is the line), so every column lines up by distance.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Threading;

namespace IRDash
{
    static partial class Analysis
    {
        // a mistake in a formula or a request, said in plain words (Pos = character in the formula, 1-based, or 0)
        sealed class ProErr : Exception
        {
            public int Pos;
            public ProErr(string m, int pos) : base(m) { Pos = pos; }
            public ProErr(string m) : base(m) { }
        }

        // ---------------- derived channels (the same formulas as derive() in workbench.js) ----------------
        sealed class DerDef { public string Key, Label, Unit, Formula; }
        static readonly string[] Wheels4 = { "LF", "RF", "LR", "RR" };
        static readonly List<DerDef> Ders = MakeDers();

        static List<DerDef> MakeDers()
        {
            List<DerDef> l = new List<DerDef>();
            Action<string, string, string, string> a = delegate (string k, string lab, string u, string f) { DerDef d = new DerDef(); d.Key = k; d.Label = lab; d.Unit = u; d.Formula = f; l.Add(d); };
            a("latG", "Lateral G", "g", "LatAccel / 9.81"); a("longG", "Longitudinal G", "g", "LongAccel / 9.81"); a("gTot", "G total", "g", "sqrt(latG^2 + longG^2)");
            a("kmh", "Speed", "km/h", "Speed * 3.6"); a("thrPct", "Throttle", "%", "Throttle * 100"); a("brkPct", "Brake", "%", "Brake * 100");
            a("steerDeg", "Steering angle", "deg", "SteeringWheelAngle in degrees"); a("beta", "Chassis slip angle", "deg", "atan(VelocityY / VelocityX) in degrees");
            a("wfPct", "Wheel force", "%", "SteeringWheelPctTorque * 100");
            foreach (string w in Wheels4) a("slip" + w, "Wheel slip " + w, "%", "(" + w + "speed - Speed) / Speed * 100");
            a("slipFront", "Front wheel slip", "%", "(slipLF + slipRF) / 2"); a("slipRear", "Rear wheel slip", "%", "(slipLR + slipRR) / 2");
            foreach (string w in Wheels4) a("ride" + w, "Ride height " + w, "mm", w + "rideHeight * 1000");
            a("rake", "Rake", "mm", "rear ride height - front ride height");
            foreach (string w in Wheels4) a("defl" + w, "Damper position " + w, "mm", w + "shockDefl * 1000");
            foreach (string w in Wheels4) a("vel" + w, "Damper speed " + w, "mm/s", w + "shockVel * 1000");
            return l;
        }
        static DerDef FindDer(string key) { foreach (DerDef d in Ders) if (d.Key == key) return d; return null; }
        static DerDef FindDerCi(string key) { foreach (DerDef d in Ders) if (string.Equals(d.Key, key, StringComparison.OrdinalIgnoreCase)) return d; return null; }

        // what a derived channel is made of (raw channel names or other derived keys)
        static string[] DerNeeds(string key)
        {
            switch (key)
            {
                case "latG": return new[] { "LatAccel" };
                case "longG": return new[] { "LongAccel" };
                case "gTot": return new[] { "latG", "longG" };
                case "kmh": return new[] { "Speed" };
                case "thrPct": return new[] { "Throttle" };
                case "brkPct": return new[] { "Brake" };
                case "steerDeg": return new[] { "SteeringWheelAngle" };
                case "beta": return new[] { "VelocityX", "VelocityY" };
                case "wfPct": return new[] { "SteeringWheelPctTorque" };
                case "slipFront": return new[] { "slipLF", "slipRF" };
                case "slipRear": return new[] { "slipLR", "slipRR" };
                case "rake": return new[] { "rideLF", "rideRF", "rideLR", "rideRR" };
            }
            if (key.Length == 6 && key.StartsWith("slip", StringComparison.Ordinal)) return new[] { key.Substring(4) + "speed", "Speed" };
            if (key.Length == 6 && key.StartsWith("ride", StringComparison.Ordinal)) return new[] { key.Substring(4) + "rideHeight" };
            if (key.Length == 6 && key.StartsWith("defl", StringComparison.Ordinal)) return new[] { key.Substring(4) + "shockDefl" };
            if (key.Length == 5 && key.StartsWith("vel", StringComparison.Ordinal)) return new[] { key.Substring(3) + "shockVel" };
            return new string[0];
        }

        static float[] DerCompute(string key, Func<string, float[]> get, int n)
        {
            float[] o = new float[n]; int i;
            string[] need = DerNeeds(key);
            float[] a = need.Length > 0 ? get(need[0]) : null, b = need.Length > 1 ? get(need[1]) : null;
            switch (key)
            {
                case "latG": case "longG": for (i = 0; i < n; i++) o[i] = (float)(a[i] / 9.81); break;
                case "gTot": for (i = 0; i < n; i++) o[i] = (float)Math.Sqrt((double)a[i] * a[i] + (double)b[i] * b[i]); break;
                case "kmh": for (i = 0; i < n; i++) o[i] = (float)(a[i] * 3.6); break;
                case "thrPct": case "brkPct": case "wfPct": for (i = 0; i < n; i++) o[i] = (float)(a[i] * 100); break;
                case "steerDeg": for (i = 0; i < n; i++) o[i] = (float)(a[i] * 57.2958); break;
                case "beta": for (i = 0; i < n; i++) o[i] = (float)(Math.Atan2(b[i], Math.Max(1.0, (double)a[i])) * 57.2958); break;   // VelocityX = a, VelocityY = b
                case "slipFront": case "slipRear": for (i = 0; i < n; i++) o[i] = (float)(((double)a[i] + b[i]) / 2); break;
                case "rake":
                    {
                        float[] c = get(need[2]), d = get(need[3]);
                        for (i = 0; i < n; i++) o[i] = (float)(((double)c[i] + d[i]) / 2 - ((double)a[i] + b[i]) / 2);   // rear (LR, RR) minus front (LF, RF)
                        break;
                    }
                default:
                    if (key.StartsWith("slip", StringComparison.Ordinal)) { for (i = 0; i < n; i++) o[i] = (float)(b[i] > 8 ? ((double)a[i] - b[i]) / b[i] * 100 : 0); }
                    else if (key.StartsWith("ride", StringComparison.Ordinal) || key.StartsWith("defl", StringComparison.Ordinal) || key.StartsWith("vel", StringComparison.Ordinal)) { for (i = 0; i < n; i++) o[i] = (float)(a[i] * 1000); }
                    else throw new ProErr("I do not know the channel \"" + key + "\".");
                    break;
            }
            return o;
        }

        // The arrays one lap's formulas can read: raw channels of the file plus derived ones, made on first use.
        sealed class ProEnv
        {
            public int N;
            public Dictionary<string, float[]> Raw = new Dictionary<string, float[]>(StringComparer.Ordinal);
            public HashSet<string> Missing = new HashSet<string>(StringComparer.Ordinal);
            Dictionary<string, float[]> memo = new Dictionary<string, float[]>(StringComparer.Ordinal);
            public float[] Get(string key)
            {
                float[] v;
                if (memo.TryGetValue(key, out v)) return v;
                if (FindDer(key) != null) v = DerCompute(key, Get, N);
                else if (!Raw.TryGetValue(key, out v) || Missing.Contains(key)) throw new ProErr("This car's file has no channel called \"" + key + "\".");
                memo[key] = v;
                return v;
            }
            public bool Has(string key)
            {
                try { Get(key); return true; } catch (ProErr) { return false; }
            }
        }

        // ---------------- the formula language ----------------
        abstract class Nd { public abstract double At(ProRun r, int i); }
        sealed class ProRun { public ProEnv Env; public long DivZero; }
        sealed class NNum : Nd { public double V; public override double At(ProRun r, int i) { return V; } }
        sealed class NVar : Nd { public string Key; public override double At(ProRun r, int i) { return r.Env.Get(Key)[i]; } }
        sealed class NUn : Nd
        {
            public char Op; public Nd A;
            public override double At(ProRun r, int i)
            {
                double a = A.At(r, i);
                if (double.IsNaN(a)) return double.NaN;
                return Op == '-' ? -a : Op == '!' ? (a == 0 ? 1 : 0) : a;
            }
        }
        sealed class NBin : Nd
        {
            public string Op; public Nd A, B;
            public override double At(ProRun r, int i)
            {
                double a = A.At(r, i), b = B.At(r, i);
                if (double.IsNaN(a) || double.IsNaN(b)) return double.NaN;
                switch (Op)
                {
                    case "+": return a + b;
                    case "-": return a - b;
                    case "*": return a * b;
                    case "/": if (b == 0) { r.DivZero++; return double.NaN; } return a / b;
                    case "%": if (b == 0) { r.DivZero++; return double.NaN; } return a - b * Math.Floor(a / b);
                    case "^": return Math.Pow(a, b);
                    case "<": return a < b ? 1 : 0;
                    case ">": return a > b ? 1 : 0;
                    case "<=": return a <= b ? 1 : 0;
                    case ">=": return a >= b ? 1 : 0;
                    case "==": return a == b ? 1 : 0;
                    case "!=": return a != b ? 1 : 0;
                    case "&&": return a != 0 && b != 0 ? 1 : 0;
                    case "||": return a != 0 || b != 0 ? 1 : 0;
                }
                return double.NaN;
            }
        }
        sealed class NIf : Nd
        {
            public Nd C, T, F;
            public override double At(ProRun r, int i)
            {
                double c = C.At(r, i);          // only the branch that is taken is worked out, so if(Speed > 1, 100 / Speed, 0) never divides by zero
                if (double.IsNaN(c)) return double.NaN;
                return c != 0 ? T.At(r, i) : F.At(r, i);
            }
        }
        sealed class NFun : Nd
        {
            public string Name; public Nd[] Args;
            public override double At(ProRun r, int i)
            {
                double[] v = new double[Args.Length];
                for (int k = 0; k < v.Length; k++) { v[k] = Args[k].At(r, i); if (double.IsNaN(v[k])) return double.NaN; }
                switch (Name)
                {
                    case "abs": return Math.Abs(v[0]);
                    case "sqrt": return v[0] < 0 ? double.NaN : Math.Sqrt(v[0]);
                    case "sin": return Math.Sin(v[0]);
                    case "cos": return Math.Cos(v[0]);
                    case "tan": return Math.Tan(v[0]);
                    case "asin": return Math.Asin(v[0]);
                    case "acos": return Math.Acos(v[0]);
                    case "atan": return Math.Atan(v[0]);
                    case "atan2": return Math.Atan2(v[0], v[1]);
                    case "exp": return Math.Exp(v[0]);
                    case "ln": return v[0] <= 0 ? double.NaN : Math.Log(v[0]);
                    case "log10": return v[0] <= 0 ? double.NaN : Math.Log10(v[0]);
                    case "pow": return Math.Pow(v[0], v[1]);
                    case "min": { double m = v[0]; for (int k = 1; k < v.Length; k++) if (v[k] < m) m = v[k]; return m; }
                    case "max": { double m = v[0]; for (int k = 1; k < v.Length; k++) if (v[k] > m) m = v[k]; return m; }
                    case "round":
                        if (v.Length == 1) return Math.Round(v[0], MidpointRounding.AwayFromZero);
                        { int dg = (int)Math.Max(0, Math.Min(9, Math.Round(v[1]))); return Math.Round(v[0], dg, MidpointRounding.AwayFromZero); }
                    case "floor": return Math.Floor(v[0]);
                    case "ceil": return Math.Ceiling(v[0]);
                    case "sign": return v[0] > 0 ? 1 : v[0] < 0 ? -1 : 0;
                    case "deg": return v[0] * 180 / Math.PI;
                    case "rad": return v[0] * Math.PI / 180;
                    case "clamp": return v[0] < v[1] ? v[1] : v[0] > v[2] ? v[2] : v[0];
                    case "hypot": return Math.Sqrt(v[0] * v[0] + v[1] * v[1]);
                }
                return double.NaN;
            }
        }

        sealed class ProExpr { public Nd Root; public HashSet<string> Used = new HashSet<string>(StringComparer.Ordinal); }

        // function name -> fewest, most arguments
        static readonly Dictionary<string, int[]> ProFuncs = MakeFuncs();
        static Dictionary<string, int[]> MakeFuncs()
        {
            Dictionary<string, int[]> d = new Dictionary<string, int[]>(StringComparer.Ordinal);
            foreach (string f in new[] { "abs", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "exp", "ln", "log10", "floor", "ceil", "sign", "deg", "rad" }) d[f] = new[] { 1, 1 };
            d["atan2"] = new[] { 2, 2 }; d["pow"] = new[] { 2, 2 }; d["hypot"] = new[] { 2, 2 }; d["min"] = new[] { 2, 8 }; d["max"] = new[] { 2, 8 };
            d["round"] = new[] { 1, 2 }; d["clamp"] = new[] { 3, 3 }; d["if"] = new[] { 3, 3 };
            return d;
        }

        // The names a formula may use in one file: its own channels (any capitals), the derived ones, pi and g.
        sealed class ProNames
        {
            public Dictionary<string, string> Vars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);     // lower -> the file's spelling
            public bool Has(string raw) { return Vars.ContainsKey(raw); }
        }
        static readonly Dictionary<string, string[]> varCache = new Dictionary<string, string[]>();
        static ProNames NamesOf(string path)
        {
            string stamp = path + "|" + File.GetLastWriteTimeUtc(path).Ticks.ToString(Inv);
            string[] list;
            lock (gate) { if (!varCache.TryGetValue(stamp, out list)) list = null; }
            if (list == null)
            {
                TrackMaps.Ibt t = TrackMaps.OpenIbt(path, true);
                if (t == null) throw new ProErr("That lap file could not be read.");
                using (t.fs) { list = new string[t.vars.Count]; t.vars.Keys.CopyTo(list, 0); }
                lock (gate) { if (varCache.Count > 12) varCache.Clear(); varCache[stamp] = list; }
            }
            ProNames pn = new ProNames();
            foreach (string s in list) pn.Vars[s] = s;
            return pn;
        }

        static int Lev(string a, string b)
        {
            int[,] d = new int[a.Length + 1, b.Length + 1];
            for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
            for (int j = 0; j <= b.Length; j++) d[0, j] = j;
            for (int i = 1; i <= a.Length; i++)
                for (int j = 1; j <= b.Length; j++)
                    d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            return d[a.Length, b.Length];
        }
        static string Closest(string word, ProNames pn)
        {
            string best = null; int bd = 99; string lw = word.ToLowerInvariant();
            Action<string> tryIt = delegate (string c) { int d = Lev(lw, c.ToLowerInvariant()); if (d < bd) { bd = d; best = c; } };
            foreach (string v in pn.Vars.Values) tryIt(v);
            foreach (DerDef d in Ders) tryIt(d.Key);
            foreach (string f in ProFuncs.Keys) tryIt(f);
            return best != null && bd <= Math.Max(2, word.Length / 3) ? best : null;
        }

        sealed class ProParser
        {
            string s; int p, depth, nodes; ProNames pn; ProExpr ex = new ProExpr();
            public static ProExpr Parse(string text, ProNames names)
            {
                string t = (text ?? "").Trim();
                if (t.Length == 0) throw new ProErr("Type a formula, for example Speed * 3.6 or abs(SteeringWheelAngle).");
                if (t.Length > 400) throw new ProErr("That formula is too long (400 characters at most).");
                ProParser q = new ProParser(); q.s = t; q.pn = names;
                q.ex.Root = q.Or();
                q.Skip();
                if (q.p < q.s.Length)
                {
                    char c = q.s[q.p];
                    if (c == ')') throw new ProErr("There is a \")\" with no \"(\" before it (character " + (q.p + 1) + ").", q.p + 1);
                    if (c == ',') throw new ProErr("A comma only belongs inside a function, like max(Speed, 20) (character " + (q.p + 1) + ").", q.p + 1);
                    throw new ProErr("I did not expect \"" + q.Rest() + "\" here (character " + (q.p + 1) + "). Is there a + - * / missing before it?", q.p + 1);
                }
                return q.ex;
            }
            string Rest() { int e = Math.Min(s.Length, p + 12); return s.Substring(p, e - p); }
            void Skip() { while (p < s.Length && char.IsWhiteSpace(s[p])) p++; }
            bool Eat(string op) { Skip(); if (string.CompareOrdinal(s, p, op, 0, op.Length) == 0) { p += op.Length; return true; } return false; }
            Nd Node(Nd n) { if (++nodes > 300) throw new ProErr("That formula is too big (300 parts at most)."); return n; }

            Nd Or() { Nd a = And(); while (Eat("||")) { NBin b = new NBin(); b.Op = "||"; b.A = a; b.B = And(); a = Node(b); } return a; }
            Nd And() { Nd a = Cmp(); while (Eat("&&")) { NBin b = new NBin(); b.Op = "&&"; b.A = a; b.B = Cmp(); a = Node(b); } return a; }
            Nd Cmp()
            {
                Nd a = Add();
                while (true)
                {
                    string op = null;
                    foreach (string o in new[] { "==", "!=", "<=", ">=", "<", ">" }) if (Eat(o)) { op = o; break; }
                    if (op == null) { Skip(); if (p < s.Length && s[p] == '=') throw new ProErr("Use == to compare two values (character " + (p + 1) + ").", p + 1); return a; }
                    NBin b = new NBin(); b.Op = op; b.A = a; b.B = Add(); a = Node(b);
                }
            }
            Nd Add()
            {
                Nd a = Mul();
                while (true)
                {
                    Skip();
                    if (p < s.Length && (s[p] == '+' || s[p] == '-')) { NBin b = new NBin(); b.Op = s[p].ToString(); p++; b.A = a; b.B = Mul(); a = Node(b); }
                    else return a;
                }
            }
            Nd Mul()
            {
                Nd a = Unary();
                while (true)
                {
                    Skip();
                    if (p < s.Length && (s[p] == '*' || s[p] == '/' || s[p] == '%')) { NBin b = new NBin(); b.Op = s[p].ToString(); p++; b.A = a; b.B = Unary(); a = Node(b); }
                    else return a;
                }
            }
            Nd Unary()
            {
                Skip();
                if (++depth > 40) throw new ProErr("That formula has too many brackets inside brackets.");
                try
                {
                    if (p < s.Length && (s[p] == '-' || s[p] == '+' || (s[p] == '!' && !(p + 1 < s.Length && s[p + 1] == '='))))
                    {
                        NUn u = new NUn(); u.Op = s[p]; p++; u.A = Unary(); return Node(u);
                    }
                    Nd a = Primary();
                    Skip();
                    if (p < s.Length && s[p] == '^') { p++; NBin b = new NBin(); b.Op = "^"; b.A = a; b.B = Unary(); return Node(b); }   // 2^3^2 = 2^(3^2); -2^2 = -(2^2)
                    return a;
                }
                finally { depth--; }
            }
            Nd Primary()
            {
                Skip();
                if (p >= s.Length) throw new ProErr("The formula stops too early: I expected a number or a channel name at the end.", s.Length);
                char c = s[p];
                if (char.IsDigit(c) || (c == '.' && p + 1 < s.Length && char.IsDigit(s[p + 1]))) return Number();
                if (c == '(')
                {
                    int open = p + 1; p++;
                    Nd a = Or(); Skip();
                    if (p >= s.Length || s[p] != ')') throw new ProErr("The bracket opened at character " + open + " is never closed: add \")\".", open);
                    p++; return a;
                }
                if (c == '[') return Bracketed();
                if (char.IsLetter(c) || c == '_') return Name();
                if (c == ')') throw new ProErr("I expected a number or a channel name before the \")\" (character " + (p + 1) + ").", p + 1);
                if (c == '*' || c == '/' || c == '%' || c == '^' || c == ',' || c == '<' || c == '>' || c == '=' || c == '&' || c == '|')
                    throw new ProErr("I expected a number or a channel name before \"" + c + "\" (character " + (p + 1) + ").", p + 1);
                throw new ProErr("I do not understand \"" + Rest() + "\" (character " + (p + 1) + "). Use numbers, channel names, + - * / ^ and brackets.", p + 1);
            }
            Nd Number()
            {
                int st = p;
                while (p < s.Length && (char.IsDigit(s[p]) || s[p] == '.')) p++;
                if (p < s.Length && (s[p] == 'e' || s[p] == 'E'))
                {
                    int q = p + 1; if (q < s.Length && (s[q] == '+' || s[q] == '-')) q++;
                    if (q < s.Length && char.IsDigit(s[q])) { while (q < s.Length && char.IsDigit(s[q])) q++; p = q; }
                }
                string txt = s.Substring(st, p - st); double v;
                if (!double.TryParse(txt, NumberStyles.Float, Inv, out v)) throw new ProErr("\"" + txt + "\" is not a number (character " + (st + 1) + ").", st + 1);
                if (p < s.Length && (char.IsLetter(s[p]) || s[p] == '_')) throw new ProErr("Write a * between a number and a name: 3 * Speed, not 3Speed (character " + (p + 1) + ").", p + 1);
                NNum n = new NNum(); n.V = v; return Node(n);
            }
            Nd Bracketed()
            {
                int st = p; p++;
                int e = s.IndexOf(']', p);
                if (e < 0) throw new ProErr("The \"[\" at character " + (st + 1) + " is never closed: add \"]\".", st + 1);
                string text = s.Substring(p, e - p).Trim(); p = e + 1;
                string key = null;
                string raw; if (pn.Vars.TryGetValue(text, out raw)) key = raw;
                if (key == null) foreach (DerDef d in Ders) if (string.Equals(d.Label + " " + d.Unit, text, StringComparison.OrdinalIgnoreCase)) { key = d.Key; break; }
                if (key == null) foreach (DerDef d in Ders) if (string.Equals(d.Label, text, StringComparison.OrdinalIgnoreCase)) { key = d.Key; break; }
                if (key == null) { DerDef d = FindDerCi(text); if (d != null) key = d.Key; }
                if (key == null) throw new ProErr("I do not know the channel [" + text + "]. Use a name from the channel list, like [Lateral G] or [Wheel slip LF].", st + 1);
                return Var(key);
            }
            Nd Var(string key) { ex.Used.Add(key); NVar v = new NVar(); v.Key = key; return Node(v); }
            Nd Name()
            {
                int st = p;
                while (p < s.Length && (char.IsLetterOrDigit(s[p]) || s[p] == '_')) p++;
                string w = s.Substring(st, p - st);
                int save = p; Skip();
                if (p < s.Length && s[p] == '(') return Call(w, st);
                p = save;
                if (w == "pi" || w == "PI" || w == "Pi") { NNum n = new NNum(); n.V = Math.PI; return Node(n); }
                if (w == "g") { NNum n = new NNum(); n.V = 9.81; return Node(n); }
                string raw;
                if (pn.Vars.TryGetValue(w, out raw))
                {
                    int idx = -1;                          // an element of an array channel: CarIdxLapDistPct[3] (no space before the "[")
                    if (p < s.Length && s[p] == '[')
                    {
                        int e = s.IndexOf(']', p);
                        if (e > p + 1 && int.TryParse(s.Substring(p + 1, e - p - 1), NumberStyles.None, Inv, out idx)) p = e + 1; else idx = -1;
                    }
                    return Var(idx >= 0 ? raw + "[" + idx.ToString(Inv) + "]" : raw);
                }
                DerDef d = FindDerCi(w);
                if (d != null) return Var(d.Key);
                if (ProFuncs.ContainsKey(w.ToLowerInvariant())) throw new ProErr("\"" + w + "\" is a function: write it with brackets, like " + w.ToLowerInvariant() + "(Speed) (character " + (st + 1) + ").", st + 1);
                string near = Closest(w, pn);
                throw new ProErr("Unknown name \"" + w + "\" (character " + (st + 1) + ")." + (near != null ? " Try " + near + "." : " Use a channel name, like Speed, Throttle or LatAccel."), st + 1);
            }
            Nd Call(string w, int st)
            {
                string f = w.ToLowerInvariant(); int[] ar;
                if (!ProFuncs.TryGetValue(f, out ar))
                {
                    string near = null; int bd = 99;
                    foreach (string k in ProFuncs.Keys) { int d = Lev(f, k); if (d < bd) { bd = d; near = k; } }
                    throw new ProErr("\"" + w + "\" is not a function (character " + (st + 1) + ")." + (near != null && bd <= 2 ? " Try " + near + "." : " Functions: " + string.Join(", ", new List<string>(ProFuncs.Keys).ToArray()) + "."), st + 1);
                }
                p++;                                       // the "("
                List<Nd> args = new List<Nd>();
                Skip();
                if (p < s.Length && s[p] == ')') p++;
                else
                {
                    while (true)
                    {
                        args.Add(Or()); Skip();
                        if (p < s.Length && s[p] == ',') { p++; continue; }
                        if (p < s.Length && s[p] == ')') { p++; break; }
                        throw new ProErr("The bracket after " + f + " is never closed: add \")\".", st + 1);
                    }
                }
                if (args.Count < ar[0] || args.Count > ar[1])
                    throw new ProErr(f + " needs " + (ar[0] == ar[1] ? ar[0].ToString(Inv) : ar[0] + " to " + ar[1]) + " value" + (ar[1] == 1 ? "" : "s") + ", got " + args.Count + " (character " + (st + 1) + ").", st + 1);
                if (f == "if") { NIf n = new NIf(); n.C = args[0]; n.T = args[1]; n.F = args[2]; return Node(n); }
                NFun fn = new NFun(); fn.Name = f; fn.Args = args.ToArray(); return Node(fn);
            }
        }

        // The formula on every sample of one lap. NaN = left blank (divided by zero, root of a negative number ...).
        static float[] EvalOn(ProExpr ex, ProEnv env, out long divZero)
        {
            ProRun run = new ProRun(); run.Env = env;
            float[] o = new float[env.N];
            for (int i = 0; i < env.N; i++)
            {
                double v = ex.Root.At(run, i);
                float f = double.IsNaN(v) ? float.NaN : (float)v;
                o[i] = float.IsNaN(f) || float.IsInfinity(f) ? float.NaN : f;       // too big for a float (1 / 0.000000000000001) is blank too
            }
            divZero = run.DivZero;
            return o;
        }

        // ---------------- the two laps and their channels ----------------
        sealed class ProLaps
        {
            public string File, Dir; public Sess Mine; public LapTrace Me, Rf; public string RefKind = ""; public int N; public double L;
            public ProNames Names;
        }

        static ProLaps OpenLaps(string file, int lapNo, string spec, string dir, bool liveRules, out int code, out string err)
        {
            code = 200; err = null;
            List<Sess> sessions = Gather(file, dir, liveRules);
            Sess mine = sessions[0];
            CornerSet cs = LoadCorners(mine);
            LapTrace me = null;
            foreach (LapTrace lap in mine.Laps) if (lap.Lap == lapNo && (me == null || lap.Clean)) me = lap;
            if (me == null) { code = 404; err = "no such lap in this file"; return null; }
            if (!me.Clean || me.Tm == null) { code = 409; err = "lap " + lapNo.ToString(Inv) + " is not a full lap (" + me.Skip + ")"; return null; }
            List<LapTrace> clean = CleanOf(sessions);
            string kind;
            LapTrace rf = FindRefLap(clean, me, spec, sessions, cs, out kind);
            if (rf != null && (SameLap(rf, me) || rf.Tm == null)) rf = null;
            ProLaps pl = new ProLaps();
            pl.File = file; pl.Dir = dir; pl.Mine = mine; pl.Me = me; pl.Rf = rf; pl.RefKind = kind ?? ""; pl.N = me.Metres + 1; pl.L = me.LengthM;
            pl.Names = NamesOf(file);
            return pl;
        }

        sealed class ProData
        {
            public ProEnv Lap, Ref; public Dictionary<string, string> Units = new Dictionary<string, string>(StringComparer.Ordinal);
        }

        // read the raw channels the keys need (derived keys bring their own), for the lap and its reference
        static ProData ReadData(ProLaps pl, ICollection<string> keys)
        {
            HashSet<string> raw = new HashSet<string>(StringComparer.Ordinal);
            Action<string> addKey = null;
            addKey = delegate (string k)
            {
                if (FindDer(k) != null) { foreach (string d in DerNeeds(k)) addKey(d); }
                else raw.Add(k);
            };
            foreach (string k in keys) addKey(k);
            List<string> order = new List<string>(raw);
            List<Chan> chans = ParseChannels(string.Join(",", order.ToArray()));
            ProData pd = new ProData();
            pd.Lap = new ProEnv(); pd.Lap.N = pl.N;
            float[][] a = LapChannels(pl.Me, chans, pl.N, true);
            for (int c = 0; c < chans.Count; c++)
            {
                if (chans[c].Ok) { pd.Lap.Raw[chans[c].Key] = a[c]; pd.Units[chans[c].Key] = chans[c].Unit; } else pd.Lap.Missing.Add(chans[c].Key);
            }
            if (pl.Rf != null)
            {
                pd.Ref = new ProEnv(); pd.Ref.N = pl.N;
                float[][] b = LapChannels(pl.Rf, chans, pl.N, false);
                for (int c = 0; c < chans.Count; c++) if (chans[c].Ok) pd.Ref.Raw[chans[c].Key] = b[c]; else pd.Ref.Missing.Add(chans[c].Key);
            }
            return pd;
        }

        static string CarKey(string car)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char ch in (car ?? "").ToLowerInvariant()) { if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) sb.Append(ch); else if (sb.Length > 0 && sb[sb.Length - 1] != '-') sb.Append('-'); }
            string k = sb.ToString().Trim('-');
            return k.Length == 0 ? "car" : k.Length > 60 ? k.Substring(0, 60) : k;
        }
        static string SlugKey(string name)
        {
            StringBuilder sb = new StringBuilder("m_");
            foreach (char ch in (name ?? "").ToLowerInvariant()) { if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) sb.Append(ch); else if (sb[sb.Length - 1] != '_') sb.Append('_'); }
            return sb.ToString().TrimEnd('_');
        }

        // ---------------- the saved formulas, per car: data\maths\<car>.txt, one "name TAB unit TAB formula" line each ----------------
        sealed class Formula { public string Name = "", Unit = "", Expr = ""; }
        static string proStore;          // tests: the folder to use instead of data\maths
        static readonly object storeGate = new object();
        // names and units: no commas (the export list is comma separated), no @ (it marks a maths channel there), no markup characters, no control characters
        static string CleanText(string s, int max) { return CleanText(s, max, true); }
        static string CleanText(string s, int max, bool strict)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char ch in (s ?? "")) { if (ch < ' ' || (strict && (ch == ',' || ch == '@' || ch == '|' || ch == '<' || ch == '>' || ch == '"' || ch == '&'))) sb.Append(' '); else sb.Append(ch); }
            string t = System.Text.RegularExpressions.Regex.Replace(sb.ToString(), @"\s+", " ").Trim();
            return t.Length > max ? t.Substring(0, max).Trim() : t;
        }
        static string StoreFile(string carKey, bool scratch)
        {
            string root = Corners.DataRoot ?? Program.RootDir;
            string dir = proStore ?? Path.Combine(root, scratch ? @"data\maths-test" : @"data\maths");
            return Path.Combine(dir, carKey + ".txt");
        }
        static List<Formula> LoadFormulas(string carKey, bool scratch)
        {
            List<Formula> l = new List<Formula>();
            string f = StoreFile(carKey, scratch);
            lock (storeGate)
            {
                if (!File.Exists(f)) return l;
                foreach (string line in File.ReadAllLines(f, Encoding.UTF8))
                {
                    string[] p = line.Split('\t');
                    if (p.Length < 3 || p[0].Length == 0 || p[2].Length == 0) continue;
                    Formula x = new Formula(); x.Name = p[0]; x.Unit = p[1]; x.Expr = p[2]; l.Add(x);
                }
            }
            return l;
        }
        static void SaveFormulas(string carKey, bool scratch, List<Formula> l)
        {
            string f = StoreFile(carKey, scratch);
            lock (storeGate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(f));
                StringBuilder sb = new StringBuilder();
                foreach (Formula x in l) sb.Append(x.Name).Append('\t').Append(x.Unit).Append('\t').Append(x.Expr).Append("\r\n");
                string tmp = f + ".tmp";
                File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
                if (File.Exists(f)) File.Delete(f);
                File.Move(tmp, f);
            }
        }
        static string FormulasJson(string carKey, List<Formula> l)
        {
            StringBuilder sb = new StringBuilder("{\"v\":1,\"car\":" + Json_.S(carKey) + ",\"max\":12,\"formulas\":[");
            for (int i = 0; i < l.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"name\":").Append(Json_.S(l[i].Name)).Append(",\"unit\":").Append(Json_.S(l[i].Unit)).Append(",\"expr\":").Append(Json_.S(l[i].Expr)).Append(",\"key\":").Append(Json_.S(SlugKey(l[i].Name))).Append('}');
            }
            return sb.Append("]}").ToString();
        }

        // ---------------- the routes ----------------
        // path is /analysis/pro/<op>; the binary / file replies set ctype and headers, errors are JSON with a non-200 code
        public static byte[] ProRoute(string path, Dictionary<string, string> q, out int code, out string ctype, out string headers)
        {
            code = 200; ctype = "application/json; charset=utf-8"; headers = "Access-Control-Allow-Origin: *\r\n";
            string op = path.Length > 14 ? path.Substring(14) : "";
            bool scratch = Q(q, "scratch") == "1";          // tests: a separate folder (data\maths-test), never his saved formulas
            try
            {
                if (op == "formulas" || op == "save" || op == "delete")
                {
                    string carKey = CarKey(Q(q, "car"));
                    List<Formula> l = LoadFormulas(carKey, scratch);
                    if (op == "formulas") return Utf8(FormulasJson(carKey, l));
                    string name = CleanText(Q(q, "name"), 40);
                    if (name.Length == 0) { code = 400; return Utf8(Err("Give the channel a name.")); }
                    Formula old = null; foreach (Formula x in l) if (string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase)) old = x;
                    if (op == "delete") { if (old != null) l.Remove(old); SaveFormulas(carKey, scratch, l); return Utf8(FormulasJson(carKey, l)); }
                    string expr = CleanText(Q(q, "expr"), 400, false), unit = CleanText(Q(q, "unit"), 12);
                    if (expr.Length == 0) { code = 400; return Utf8(Err("Type a formula, for example Speed * 3.6 or abs(SteeringWheelAngle).")); }
                    if (old == null && l.Count >= 12) { code = 400; return Utf8(Err("12 maths channels is the most for one car: remove one first.")); }
                    if (old == null) { old = new Formula(); l.Add(old); }
                    old.Name = name; old.Unit = unit; old.Expr = expr;
                    SaveFormulas(carKey, scratch, l);
                    return Utf8(FormulasJson(carKey, l));
                }
                if (op != "maths" && op != "export") { code = 404; return Utf8(Err("not found")); }
                if (Program.IsDriving) { code = 503; return Utf8(Err("Not while driving")); }
                string id = Q(q, "id"), rf = Q(q, "ref");
                if (rf.Length == 0) rf = "pb";
                int lap;
                if (!int.TryParse(Q(q, "lap"), NumberStyles.Integer, Inv, out lap)) { code = 400; return Utf8(Err("lap must be a number")); }
                string file = ResolveFile(id);
                if (file == null) { code = 404; return Utf8(Err("no such lap file")); }
                try { if (Career.OnlineOnly(new FileInfo(file))) { code = 409; return Utf8(Err("Online-only in OneDrive: run tools\\keep-iracing-local.cmd")); } }
                catch { code = 404; return Utf8(Err("no such lap file")); }
                ThreadPriority was = Thread.CurrentThread.Priority;
                try
                {
                    Thread.CurrentThread.Priority = ThreadPriority.BelowNormal;
                    string dir = TrackMaps.TelemetryDir;
                    if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) dir = Path.GetDirectoryName(file);
                    string err;
                    ProLaps pl = OpenLaps(file, lap, rf, dir, true, out code, out err);
                    if (pl == null) return Utf8(Err(err));
                    if (op == "maths") return MathsReply(pl, Q(q, "name"), Q(q, "expr"), Q(q, "unit"), out code);
                    return ExportReply(pl, Q(q, "ch"), Q(q, "fmt"), Q(q, "which"), scratch, out code, out ctype, out headers);
                }
                finally { try { Thread.CurrentThread.Priority = was; } catch { } }
            }
            catch (ProErr pe) { code = 400; ctype = "application/json; charset=utf-8"; headers = "Access-Control-Allow-Origin: *\r\n"; return Utf8("{\"error\":" + Json_.S(pe.Message) + ",\"pos\":" + pe.Pos.ToString(Inv) + "}"); }
            catch (Exception ex) { Log.W("pro: " + ex.Message); code = 500; ctype = "application/json; charset=utf-8"; headers = "Access-Control-Allow-Origin: *\r\n"; return Utf8(Err("could not work that out")); }
        }

        // one formula on the lap and its reference, in the same PWB1 layout as /analysis/channels (channel key = m_<name>)
        static byte[] MathsReply(ProLaps pl, string nameIn, string exprIn, string unitIn, out int code)
        {
            code = 200;
            string name = CleanText(nameIn, 40), unit = CleanText(unitIn, 12);
            if (name.Length == 0) name = "Maths";
            string key = SlugKey(name);
            ProExpr ex = ProParser.Parse(exprIn, pl.Names);
            ProData pd = ReadData(pl, ex.Used);
            foreach (string k in ex.Used) pd.Lap.Get(k);                  // a channel this car's file lacks is said in words, here
            long dz1, dz2 = 0;
            float[] lapV = EvalOn(ex, pd.Lap, out dz1), refV = null;
            if (pd.Ref != null) refV = EvalOn(ex, pd.Ref, out dz2);
            int blank = 0; foreach (float v in lapV) if (float.IsNaN(v)) blank++;
            if (blank >= pl.N) throw new ProErr(dz1 > 0 ? "This formula divides by zero at every point of the lap, so there is nothing to show." : "This formula gives no value anywhere on the lap (a root or a log of a negative number?).");
            string note = blank == 0 ? "" : blank + " of " + pl.N + " points have no value" + (dz1 > 0 ? (dz1 == blank ? " (division by zero)" : " (division by zero, a root of a negative number or a number too big)") : " (a root or a log of a negative number, or a number too big)") + " and are left blank.";
            StringBuilder sb = new StringBuilder(1500);
            sb.Append("{\"v\":1,\"n\":").Append(pl.N).Append(",\"metres\":").Append(pl.Me.Metres).Append(",\"lengthM\":").Append(F(pl.L, "0.0")).Append(",\"step\":").Append(F(pl.L / pl.Me.Metres, "0.00000"));
            sb.Append(",\"track\":").Append(Json_.S(pl.Me.Track)).Append(",\"car\":").Append(Json_.S(pl.Me.Car));
            sb.Append(",\"lap\":"); AppendLapInfo(sb, pl.Me, "lap");
            sb.Append(",\"ref\":"); if (pl.Rf == null) sb.Append("null"); else AppendLapInfo(sb, pl.Rf, pl.RefKind);
            sb.Append(",\"channels\":[{\"key\":").Append(Json_.S(key)).Append(",\"name\":").Append(Json_.S(name)).Append(",\"unit\":").Append(Json_.S(unit)).Append(",\"desc\":").Append(Json_.S(exprIn.Trim())).Append(",\"ok\":true}]");
            sb.Append(",\"blank\":").Append(blank).Append(",\"note\":").Append(Json_.S(note));
            sb.Append(",\"arrays\":[\"lap.t\",\"lap.").Append(key).Append('"');
            if (refV != null) sb.Append(",\"ref.t\",\"ref.").Append(key).Append('"');
            sb.Append("]}");
            byte[] head = Utf8(sb.ToString());
            int pad = (4 - head.Length % 4) % 4, lapsOut = refV != null ? 2 : 1;
            byte[] outp = new byte[8 + head.Length + pad + lapsOut * 2 * pl.N * 4];
            outp[0] = (byte)'P'; outp[1] = (byte)'W'; outp[2] = (byte)'B'; outp[3] = (byte)'1';
            Buffer.BlockCopy(BitConverter.GetBytes(head.Length + pad), 0, outp, 4, 4);
            Buffer.BlockCopy(head, 0, outp, 8, head.Length);
            for (int i = 0; i < pad; i++) outp[8 + head.Length + i] = (byte)' ';
            int pos = 8 + head.Length + pad;
            pos = PutTime(outp, pos, pl.Me, pl.N); pos = PutFloats(outp, pos, lapV);
            if (refV != null) { pos = PutTime(outp, pos, pl.Rf, pl.N); pos = PutFloats(outp, pos, refV); }
            return outp;
        }

        // ---------------- export ----------------
        sealed class ExCol { public string Title = "", Unit = "", Source = "", Formula = "", Header = ""; public float[] Lap, Ref; }

        static string[] DefaultExport = { "kmh", "thrPct", "brkPct", "steerDeg", "Gear", "RPM", "latG", "longG", "beta", "wfPct" };

        static byte[] ExportReply(ProLaps pl, string chIn, string fmtIn, string whichIn, bool scratch, out int code, out string ctype, out string headers)
        {
            code = 200;
            string fmt = (fmtIn ?? "").ToLowerInvariant() == "csv" ? "csv" : "xlsx";
            string which = (whichIn ?? "").ToLowerInvariant(); if (which != "lap" && which != "ref") which = "both";
            bool useLap = which != "ref", useRef = pl.Rf != null && which != "lap";
            if (which == "ref" && pl.Rf == null) { useLap = true; }
            // 1. what was asked for
            List<string> asked = new List<string>();
            foreach (string part in (string.IsNullOrWhiteSpace(chIn) ? string.Join(",", DefaultExport) : chIn).Split(',')) { string t = part.Trim(); if (t.Length > 0 && asked.Count < 64 && !asked.Contains(t)) asked.Add(t); }
            List<Formula> store = LoadFormulas(CarKey(pl.Me.Car), scratch);
            List<string> keys = new List<string>(); List<ProExpr> exprs = new List<ProExpr>(); List<Formula> forms = new List<Formula>(); List<string> notes = new List<string>();
            List<string> colOrder = new List<string>();   // "k:<key>" or "m:<index>"
            foreach (string a in asked)
            {
                if (a.StartsWith("@", StringComparison.Ordinal))
                {
                    string nm = a.Substring(1).Trim(); Formula f = null;
                    foreach (Formula x in store) if (string.Equals(x.Name, nm, StringComparison.OrdinalIgnoreCase)) f = x;
                    if (f == null) { notes.Add("Left out " + nm + ": no maths channel of that name for this car."); continue; }
                    ProExpr ex;
                    try { ex = ProParser.Parse(f.Expr, pl.Names); }
                    catch (ProErr pe) { notes.Add("Left out " + nm + ": " + pe.Message); continue; }
                    foreach (string u in ex.Used) keys.Add(u);
                    exprs.Add(ex); forms.Add(f); colOrder.Add("m:" + (exprs.Count - 1));
                }
                else
                {
                    DerDef d = FindDer(a);
                    string key = a;
                    if (d == null)
                    {
                        string rawName; string baseName = a; int br = a.IndexOf('[');
                        if (br > 0) baseName = a.Substring(0, br);
                        if (!pl.Names.Vars.TryGetValue(baseName, out rawName)) { notes.Add("Left out " + a + ": this car's file has no such channel."); continue; }
                        key = br > 0 ? rawName + a.Substring(br) : rawName;
                    }
                    keys.Add(key); colOrder.Add("k:" + key);
                }
            }
            // 2. read them, lap and reference
            ProData pd = ReadData(pl, keys);
            List<ExCol> cols = new List<ExCol>(); HashSet<string> titles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string co in colOrder)
            {
                ExCol c = new ExCol();
                try
                {
                    if (co.StartsWith("m:", StringComparison.Ordinal))
                    {
                        int ix = int.Parse(co.Substring(2), Inv); Formula f = forms[ix]; long dz;
                        c.Title = f.Name; c.Unit = f.Unit; c.Source = "maths channel"; c.Formula = f.Expr;
                        c.Lap = EvalOn(exprs[ix], pd.Lap, out dz); if (pd.Ref != null) c.Ref = EvalOn(exprs[ix], pd.Ref, out dz);
                    }
                    else
                    {
                        string key = co.Substring(2); DerDef d = FindDer(key);
                        c.Lap = pd.Lap.Get(key); c.Ref = pd.Ref != null ? pd.Ref.Get(key) : null;
                        if (d != null) { c.Title = d.Label; c.Unit = d.Unit; c.Source = "derived"; c.Formula = d.Formula; }
                        else { c.Title = key; string u; c.Unit = pd.Units.TryGetValue(key, out u) ? u : ""; c.Source = "lap file"; }
                    }
                }
                catch (ProErr pe) { notes.Add("Left out " + (co.StartsWith("m:", StringComparison.Ordinal) ? forms[int.Parse(co.Substring(2), Inv)].Name : co.Substring(2)) + ": " + pe.Message); continue; }
                string unitPart = c.Unit.Length > 0 ? " (" + c.Unit + ")" : "", baseTitle = c.Title; int dup = 2;
                while (!titles.Add(c.Title + unitPart)) c.Title = baseTitle + " #" + (dup++);      // two columns with the same name and unit stay apart
                c.Header = c.Title + unitPart;
                cols.Add(c);
            }
            if (cols.Count == 0) throw new ProErr("None of those channels are in this car's file.");
            // 3. the table
            int n = pl.N, m = n - 1;
            float[] tL = new float[n], tR = pl.Rf != null ? new float[n] : null;
            for (int i = 0; i < n; i++) { double d = i >= m ? pl.L : i * pl.L / m; tL[i] = (float)TAt(pl.Me, d); if (tR != null) tR[i] = (float)TAt(pl.Rf, d); }
            List<string> head = new List<string>(); List<float[]> data = new List<float[]>(); List<int> kinds = new List<int>();   // kinds: 0 distance, 1 number
            string lapTag = "lap " + pl.Me.Lap.ToString(Inv), refTag = pl.Rf != null ? "ref " + pl.Rf.Lap.ToString(Inv) : "";
            head.Add("Distance (m)"); data.Add(null); kinds.Add(0);
            if (useLap) { head.Add("Time (s) " + lapTag); data.Add(tL); kinds.Add(1); }
            if (useRef) { head.Add("Time (s) " + refTag); data.Add(tR); kinds.Add(1); }
            foreach (ExCol c in cols)
            {
                if (useLap) { head.Add(c.Header + " " + lapTag); data.Add(c.Lap); kinds.Add(1); }
                if (useRef && c.Ref != null) { head.Add(c.Header + " " + refTag); data.Add(c.Ref); kinds.Add(1); }
            }
            string baseName2 = "Paddock-" + SafeFile(pl.Me.Track) + "-lap" + pl.Me.Lap.ToString(Inv) + (DateOf(pl.Me.File).Length >= 10 ? "-" + DateOf(pl.Me.File).Substring(0, 10) : "");
            if (fmt == "csv")
            {
                ctype = "text/csv; charset=utf-8";
                headers = "Access-Control-Allow-Origin: *\r\nContent-Disposition: attachment; filename=\"" + baseName2 + ".csv\"\r\n";
                return Utf8(CsvOf(pl, head, data, kinds));
            }
            ctype = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            headers = "Access-Control-Allow-Origin: *\r\nContent-Disposition: attachment; filename=\"" + baseName2 + ".xlsx\"\r\n";
            return XlsxOf(pl, head, data, kinds, cols, notes, useLap, useRef);
        }

        static string SafeFile(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char ch in s ?? "") { if (char.IsLetterOrDigit(ch) && ch < 128) sb.Append(ch); else if (sb.Length > 0 && sb[sb.Length - 1] != '-') sb.Append('-'); }
            string t = sb.ToString().Trim('-');
            return t.Length == 0 ? "lap" : t;
        }

        static string Num(float v) { return float.IsNaN(v) || float.IsInfinity(v) ? "" : v.ToString("R", Inv); }
        static string DistText(int i, ProLaps pl) { int m = pl.N - 1; double d = i >= m ? pl.L : i * pl.L / m; return d.ToString("0.###", Inv); }

        static string CsvQuote(string s) { return s.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0 ? "\"" + s.Replace("\"", "\"\"") + "\"" : s; }
        static string CsvOf(ProLaps pl, List<string> head, List<float[]> data, List<int> kinds)
        {
            StringBuilder sb = new StringBuilder(pl.N * head.Count * 9);
            for (int c = 0; c < head.Count; c++) { if (c > 0) sb.Append(','); sb.Append(CsvQuote(head[c])); }
            sb.Append("\r\n");
            for (int i = 0; i < pl.N; i++)
            {
                for (int c = 0; c < head.Count; c++) { if (c > 0) sb.Append(','); sb.Append(kinds[c] == 0 ? DistText(i, pl) : Num(data[c][i])); }
                sb.Append("\r\n");
            }
            return sb.ToString();
        }

        // ---- .xlsx: a zip of the smallest set of SpreadsheetML parts Excel (and LibreOffice, Numbers, Sheets) opens ----
        static string XmlEsc(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char ch in s)
            {
                if (ch == '&') sb.Append("&amp;"); else if (ch == '<') sb.Append("&lt;"); else if (ch == '>') sb.Append("&gt;"); else if (ch == '"') sb.Append("&quot;");
                else if (ch < ' ' && ch != '\t' && ch != '\n' && ch != '\r') continue; else sb.Append(ch);
            }
            return sb.ToString();
        }
        static string ColName(int c)      // 0 -> A, 25 -> Z, 26 -> AA
        {
            string s = ""; c++;
            while (c > 0) { int r = (c - 1) % 26; s = (char)('A' + r) + s; c = (c - 1) / 26; }
            return s;
        }
        static void Part(ZipArchive z, string name, string text)
        {
            ZipArchiveEntry e = z.CreateEntry(name, CompressionLevel.Optimal);
            using (Stream st = e.Open()) { byte[] b = new UTF8Encoding(false).GetBytes(text); st.Write(b, 0, b.Length); }
        }
        static string StrCell(string r, string text, bool bold) { return "<c r=\"" + r + "\" t=\"inlineStr\"" + (bold ? " s=\"1\"" : "") + "><is><t xml:space=\"preserve\">" + XmlEsc(text) + "</t></is></c>"; }

        static byte[] XlsxOf(ProLaps pl, List<string> head, List<float[]> data, List<int> kinds, List<ExCol> cols, List<string> notes, bool useLap, bool useRef)
        {
            const string NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
            const string RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
            const string DEC = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
            string dataName = "Lap " + pl.Me.Lap.ToString(Inv);
            // sheet 1: the data, header row frozen
            StringBuilder s1 = new StringBuilder(pl.N * head.Count * 14);
            s1.Append(DEC).Append("<worksheet xmlns=\"").Append(NS).Append("\"><dimension ref=\"A1:").Append(ColName(head.Count - 1)).Append(pl.N + 1).Append("\"/>");
            s1.Append("<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><cols>");
            for (int c = 0; c < head.Count; c++) s1.Append("<col min=\"").Append(c + 1).Append("\" max=\"").Append(c + 1).Append("\" width=\"").Append(Math.Max(12, Math.Min(36, head[c].Length + 2))).Append("\" customWidth=\"1\"/>");
            s1.Append("</cols><sheetData><row r=\"1\">");
            for (int c = 0; c < head.Count; c++) s1.Append(StrCell(ColName(c) + "1", head[c], true));
            s1.Append("</row>");
            for (int i = 0; i < pl.N; i++)
            {
                int row = i + 2;
                s1.Append("<row r=\"").Append(row).Append("\">");
                for (int c = 0; c < head.Count; c++)
                {
                    string v = kinds[c] == 0 ? DistText(i, pl) : Num(data[c][i]);
                    if (v.Length == 0) continue;                       // a blank point stays an empty cell
                    s1.Append("<c r=\"").Append(ColName(c)).Append(row).Append("\"><v>").Append(v).Append("</v></c>");
                }
                s1.Append("</row>");
            }
            s1.Append("</sheetData></worksheet>");
            // sheet 2: what this is
            List<string[]> info = new List<string[]>();
            info.Add(new[] { "Paddock lap export", "" });
            info.Add(new[] { "Car", pl.Me.Car }); info.Add(new[] { "Track", pl.Me.Track + (string.IsNullOrEmpty(pl.Me.Config) ? "" : " - " + pl.Me.Config) });
            info.Add(new[] { "Session file", pl.Me.File }); info.Add(new[] { "Date", DateOf(pl.Me.File) });
            info.Add(new[] { "Lap", pl.Me.Lap.ToString(Inv) }); info.Add(new[] { "Lap time (s)", F(pl.Me.Time, "0.000") });
            info.Add(new[] { "Reference lap", pl.Rf == null ? "none" : "lap " + pl.Rf.Lap.ToString(Inv) + ", " + F(pl.Rf.Time, "0.000") + " s (" + pl.RefKind + ") in " + pl.Rf.File });
            info.Add(new[] { "Rows", pl.N.ToString(Inv) + " points, about every " + F(pl.L / pl.Me.Metres, "0.00") + " m, the last one on the line" });
            info.Add(new[] { "Time", "pinned to iRacing's own lap time at the line" });
            info.Add(new[] { "", "" });
            info.Add(new[] { "Channel", "Unit", "Where it comes from", "How it is worked out" });
            foreach (ExCol c in cols) info.Add(new[] { c.Title, c.Unit, c.Source, c.Formula });
            foreach (string nt in notes) info.Add(new[] { nt, "" });
            StringBuilder s2 = new StringBuilder();
            s2.Append(DEC).Append("<worksheet xmlns=\"").Append(NS).Append("\"><cols><col min=\"1\" max=\"1\" width=\"34\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"40\" customWidth=\"1\"/><col min=\"3\" max=\"4\" width=\"30\" customWidth=\"1\"/></cols><sheetData>");
            for (int r = 0; r < info.Count; r++)
            {
                s2.Append("<row r=\"").Append(r + 1).Append("\">");
                for (int c = 0; c < info[r].Length; c++) if (info[r][c].Length > 0) s2.Append(StrCell(ColName(c) + (r + 1), info[r][c], r == 0 || r == 11));
                s2.Append("</row>");
            }
            s2.Append("</sheetData></worksheet>");
            using (MemoryStream ms = new MemoryStream())
            {
                using (ZipArchive z = new ZipArchive(ms, ZipArchiveMode.Create, true))
                {
                    Part(z, "[Content_Types].xml", DEC + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
                        "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" +
                        "<Override PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" +
                        "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>");
                    Part(z, "_rels/.rels", DEC + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
                    Part(z, "xl/workbook.xml", DEC + "<workbook xmlns=\"" + NS + "\" xmlns:r=\"" + RNS + "\"><sheets><sheet name=\"" + XmlEsc(dataName) + "\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Info\" sheetId=\"2\" r:id=\"rId2\"/></sheets></workbook>");
                    Part(z, "xl/_rels/workbook.xml.rels", DEC + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet2.xml\"/>" +
                        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>");
                    Part(z, "xl/styles.xml", DEC + "<styleSheet xmlns=\"" + NS + "\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>" +
                        "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
                        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
                        "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>" +
                        "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>");
                    Part(z, "xl/worksheets/sheet1.xml", s1.ToString());
                    Part(z, "xl/worksheets/sheet2.xml", s2.ToString());
                }
                return ms.ToArray();
            }
        }

        // ---------------- one-shot for tests\pro-tools-test.ps1: no window, no deploy, reads only the folder it is given ----------------
        //   --pro --op maths --exprs <file of "name<TAB>unit<TAB>formula" lines> --out <prefix>   -> <prefix>.<i>.bin (PWB1) or <prefix>.<i>.json (the error)
        //   --pro --op export --fmt csv|xlsx --ch a,b,@name --which both --store <folder> --out <file>
        //   --pro --op save|delete|formulas --car <name> --name --unit --expr --store <folder> --out <file>
        static int ProCli(string[] args)
        {
            string op = Arg(args, "--op"), root = Arg(args, "--root"), dir = Arg(args, "--dir"), id = Arg(args, "--id"), outPath = Arg(args, "--out"), rf = Arg(args, "--ref");
            if (rf.Length == 0) rf = "pb";
            string store = Arg(args, "--store"); if (store.Length > 0) proStore = store;
            if (root.Length > 0) { Corners.DataRoot = root; TrackMaps.MapsDir = Path.Combine(root, @"dash\maps"); }
            try
            {
                if (op == "save" || op == "delete" || op == "formulas")
                {
                    Dictionary<string, string> q = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    q["car"] = Arg(args, "--car"); q["name"] = Arg(args, "--name"); q["unit"] = Arg(args, "--unit"); q["expr"] = Arg(args, "--expr");
                    int c; string ct, hd;
                    byte[] b = ProRoute("/analysis/pro/" + op, q, out c, out ct, out hd);
                    File.WriteAllBytes(outPath, b); return c == 200 ? 0 : 1;
                }
                int lap; if (!int.TryParse(Arg(args, "--lap"), NumberStyles.Integer, Inv, out lap)) return 1;
                string file = Path.Combine(dir, id);
                int code; string err;
                ProLaps pl = OpenLaps(file, lap, rf, dir, false, out code, out err);
                if (pl == null) { File.WriteAllBytes(outPath, Utf8(Err(err))); return 1; }
                if (op == "maths")
                {
                    string[] lines = File.ReadAllLines(Arg(args, "--exprs"), Encoding.UTF8);
                    for (int i = 0; i < lines.Length; i++)
                    {
                        string[] p = lines[i].Split('\t');
                        string name = p.Length > 0 ? p[0] : "x", unit = p.Length > 1 ? p[1] : "", ex = p.Length > 2 ? p[2] : "";
                        try { File.WriteAllBytes(outPath + "." + i + ".bin", MathsReply(pl, name, ex, unit, out code)); }
                        catch (ProErr pe) { File.WriteAllBytes(outPath + "." + i + ".json", Utf8("{\"error\":" + Json_.S(pe.Message) + ",\"pos\":" + pe.Pos.ToString(Inv) + "}")); }
                    }
                    return 0;
                }
                if (op == "export")
                {
                    string ct, hd; byte[] b;
                    try { b = ExportReply(pl, Arg(args, "--ch"), Arg(args, "--fmt"), Arg(args, "--which"), false, out code, out ct, out hd); }
                    catch (ProErr pe) { File.WriteAllBytes(outPath, Utf8("{\"error\":" + Json_.S(pe.Message) + "}")); return 1; }
                    File.WriteAllBytes(outPath, b); return 0;
                }
            }
            catch (Exception ex) { try { File.WriteAllBytes(outPath, Utf8(Err(ex.Message))); } catch { } return 1; }
            return 1;
        }
    }
}
