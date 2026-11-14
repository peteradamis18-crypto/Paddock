// Entry point for tests\review-test.ps1 only: compiled with dash\src\*.cs (the build.ps1 list, csc /main:IRDash.ReviewMain) into a
// throw-away exe in %TEMP%, so the review engine (dash\src\review.cs) is asked about real telemetry offline, without irdash.
//   review.exe <root> <work dir> <telemetry dir> <12 Nov race> <13 Nov race | -> <2-lap cut> <no-lap cut>
// Prints "ok ..." / "FAIL ..." / "skip ..." lines and DONE; the test counts them. Reads the .ibt files only; writes only <work dir>.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IRDash
{
    static class ReviewMain
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static void Ok(string what, bool cond, string why) { Console.WriteLine((cond ? "ok " : "FAIL ") + what + (cond || string.IsNullOrEmpty(why) ? "" : " (" + why + ")")); }
        static void Ok(string what, bool cond) { Ok(what, cond, ""); }
        static void Skip(string what) { Console.WriteLine("skip " + what); }

        static Dictionary<string, object> Obj(string j) { try { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(j) as Dictionary<string, object>; } catch { return null; } }
        static object G(object d, string k) { Dictionary<string, object> x = d as Dictionary<string, object>; object o; return x != null && x.TryGetValue(k, out o) ? o : null; }
        static object[] A(object o) { return o as object[] ?? new object[0]; }
        static double D(object o) { double v; return o != null && double.TryParse(Convert.ToString(o, Inv), NumberStyles.Float, Inv, out v) ? v : double.NaN; }
        static int I(object o) { double v = D(o); return double.IsNaN(v) ? -999 : (int)Math.Round(v); }
        static string S(object o) { return o == null ? "" : Convert.ToString(o, Inv); }
        static string Short(string j) { return j == null ? "null" : (j.Length > 400 ? j.Substring(0, 400) + "..." : j); }

        static string Route(string path, string query, out int code)
        {
            Dictionary<string, string> q = new Dictionary<string, string>();
            foreach (string kv in query.Split('&')) { int e = kv.IndexOf('='); if (e > 0) q[kv.Substring(0, e)] = Uri.UnescapeDataString(kv.Substring(e + 1)); }
            string type; byte[] b = Review.Route(path, q, out code, out type);
            return type.StartsWith("application/octet", StringComparison.Ordinal) ? "BIN:" + Encoding.ASCII.GetString(b, 0, Math.Min(4, b.Length)) + ":" + Encoding.UTF8.GetString(b, 8, Math.Min(b.Length - 8, 20000)) : Encoding.UTF8.GetString(b);
        }

        // the "card" checks every review must pass: at most 3, ranked by loss, the words lint clean
        static void Cards(string tag, Dictionary<string, object> rv, bool advice)
        {
            object[] cards = A(G(rv, "cards"));
            double last = double.MaxValue; bool ranked = true, lint = true, sample = true, adv = true; string bad = "";
            foreach (object c in cards)
            {
                double lost = D(G(c, "lost")); if (lost > last + 1e-9) ranked = false; last = lost;
                string line = S(G(G(c, "corner"), "label")) + ": " + S(G(c, "happened"));
                string r1 = Review.Lint(line), r2 = Review.LintLine(S(G(c, "tryThis")));
                if (r1 != null || r2 != null) { lint = false; bad = line + " | " + S(G(c, "tryThis")) + " -> " + (r1 ?? r2); }
                if (S(G(c, "sample")).Length == 0) sample = false;
                if (advice != (S(G(c, "tryThis")).Length > 0)) adv = false;
            }
            Ok(tag + ": at most 3 cards, ranked by seconds lost", cards.Length <= 3 && ranked);
            Ok(tag + ": every card passes Lint (a corner and a number, 14 words at most, nothing on the never-say list)", lint, bad);
            Ok(tag + ": every card says its sample size", sample);
            Ok(tag + (advice ? ": every card has a \"try this\" line" : ": no advice on any card"), adv);
        }

        static int Main(string[] a)
        {
            string root = a[0], work = a[1], tele = a[2], f12 = a[3], f13 = a[4] == "-" ? null : a[4], cut2 = a[5], cut0 = a[6];
            LapStore.Dir = Path.Combine(work, "laps"); Review.Dir = Path.Combine(work, "review");
            Vault.Root = Path.Combine(work, "vault"); Directory.CreateDirectory(Path.Combine(Vault.Root, "field"));
            RaceField.Init(work);
            Corners.DataRoot = Directory.Exists(Path.Combine(work, @"data\corners")) ? work : root; TrackMaps.MapsDir = Path.Combine(root, @"dash\maps"); TrackMaps.TelemetryDir = tele;
            Jobs.GraceMs = 300;
            bool on = false; Jobs.SessionOn = delegate { return on; };

            // ---------------------------------------------------------------- 1. the 12 Nov race
            Console.WriteLine("section 1. the 12 Nov race (lap truth on the review too)");
            string j12 = Review.BuildNow(f12);
            Dictionary<string, object> rv = Obj(j12), ses = G(rv, "session") as Dictionary<string, object>;
            Ok("1. the review is ready", S(G(rv, "state")) == "ready", Short(j12));
            Ok("1. best 1:33.832 on lap 9", Math.Abs(D(G(G(ses, "best"), "time")) - 93.832) < 0.0005 && I(G(G(ses, "best"), "lap")) == 9, Short(S(new JavaScriptSerializer().Serialize(G(ses, "best")))));
            Ok("1. 10 laps, 7 counted (session.laps / session.clean)", I(G(ses, "laps")) == 10 && I(G(ses, "clean")) == 7, G(ses, "laps") + "/" + G(ses, "clean"));
            int cnt = 0, pbs = 0, pbLap = 0; foreach (object l in A(G(rv, "laps"))) { if (G(l, "counted") is bool && (bool)G(l, "counted")) cnt++; if (G(l, "pb") is bool && (bool)G(l, "pb")) { pbs++; pbLap = I(G(l, "n")); } }
            Ok("1. the lap list: 7 counted, one pb (lap 9)", cnt == 7 && pbs == 1 && pbLap == 9, cnt + " counted, pb " + pbLap);
            Ok("1. the type is Race, units imperial", S(G(ses, "type")) == "Race" && S(G(rv, "units")) == "imperial");
            Ok("1. the reference is this session's lap 9 (kind session)", S(G(G(ses, "ref"), "kind")) == "session" && I(G(G(ses, "ref"), "lap")) == 9);
            object[] cards = A(G(rv, "cards"));
            Ok("1. three cards", cards.Length == 3, cards.Length + " cards, note " + S(G(rv, "note")));
            Cards("1", rv, true);
            foreach (object c in cards) Console.WriteLine("info card " + I(G(c, "rank")) + " " + S(G(G(c, "corner"), "label")) + " " + S(G(c, "lost")) + " s | " + S(G(c, "happened")) + " | " + S(G(c, "tryThis")) + " | " + S(G(c, "sample")) + " | " + S(G(c, "phase")));
            string plan = S(G(rv, "plan"));
            Console.WriteLine("info plan " + plan);
            if (cards.Length > 0)
            {
                string lab = S(G(G(cards[0], "corner"), "label")), name = S(G(G(cards[0], "corner"), "name"));
                string spoken = lab.StartsWith("T") ? "Turn " + lab.Substring(1) : lab;
                Ok("1. the plan names card 1's corner and lints clean", plan.StartsWith("Next time: ") && (plan.Contains(spoken) || (name.Length > 0 && plan.Contains(name))) && Review.Lint(plan) == null, plan + " / " + Review.Lint(plan));
            }
            object[] gain = A(G(G(rv, "map"), "gain")); double sum = 0; foreach (object g in gain) sum += D(g);
            int mapLap = I(G(G(rv, "map"), "lap")); double lapT = double.NaN; foreach (object l in A(G(rv, "laps"))) if (I(G(l, "n")) == mapLap) lapT = D(G(l, "time"));
            Ok("1. map.gain: 100 values summing to about best - lap " + mapLap, gain.Length == 100 && Math.Abs(sum - (93.832 - lapT)) < 0.05, "sum " + sum.ToString("0.000", Inv) + " vs " + (93.832 - lapT).ToString("0.000", Inv));
            Ok("1. map.marks: one per card", A(G(G(rv, "map"), "marks")).Length == cards.Length);
            Ok("1. the optimal lap is no slower than the best", D(G(G(rv, "optimal"), "time")) <= 93.832 + 0.001 && A(G(G(rv, "optimal"), "from")).Length == 24, S(G(G(rv, "optimal"), "time")));
            Ok("1. no note on a session with 7 clean laps", G(rv, "note") == null);
            Ok("1. no field log here: race is null", G(rv, "race") == null);
            Ok("1. the cache file is written (and no .tmp is left)", File.Exists(Review.CachePath(f12)) && File.Exists(Review.CornersPath(f12)) && Directory.GetFiles(Review.Dir, "*.tmp").Length == 0);
            Ok("1. the cache answers the same review", Review.Cached(f12) == j12);

            // ---------------------------------------------------------------- 3. the 13 Nov race with its field log
            Console.WriteLine("section 3. the 13 Nov race");
            if (f13 == null) Skip("3. the 13 Nov 16-27-02 race file is not readable here: section 3 and the 'ever' reference of section 5 cannot run");
            else
            {
                FileLaps fl = LapStore.ForFile(f13);
                string yaml; using (IbtFile t = IbtFile.Open(f13, false)) yaml = t.Yaml;
                int sn = -1; foreach (LapRec l in fl.Laps) if (Career.SessionTypeOf(yaml, l.SessionNum).ToLowerInvariant().Contains("race")) sn = l.SessionNum;
                int maxLap = 0; foreach (LapRec l in LapStore.OfSession(fl, sn)) if (l.N > maxLap) maxLap = l.N;
                Ok("3. the file holds a race with laps", sn >= 0 && maxLap >= 3, "session " + sn + ", " + maxLap + " laps");
                // a field log for that race: 19 cars, Peter (idx 3) from P7 to P4, in traffic for the first half, clean air after it.
                // (The real log of that race is in the rig's vault\field: the lead checks it live.)
                FileInfo fi = new FileInfo(f13);
                long start = (long)(IbtFile.StartFromName(fi.Name) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
                long end = (long)(fi.LastWriteTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
                RfData d = new RfData(); d.Id = "f20261113-162702-" + sn; d.StartMs = start + 60000; d.EndMs = end - 30000; d.Track = fl.Track; d.TrackName = fl.Track; d.Config = fl.Config;
                d.TrackId = fl.TrackId; d.SessNum = sn; d.SessType = "Race"; d.Me = 3; d.LengthM = 4088;
                int[] pos = new int[maxLap + 1];
                for (int n = 1; n <= maxLap; n++) pos[n] = Math.Max(4, 7 - (n - 1) * 3 / Math.Max(1, maxLap - 2));
                pos[maxLap] = 4;
                int other = 0;
                for (int idx = 0; idx < 19; idx++)
                {
                    RfCar c = new RfCar(); c.Idx = idx; c.Me = idx == 3; c.Cls = "4083"; c.ClsName = "GR86"; c.IR = 1500 + idx * 20; c.Num = (idx + 10).ToString(Inv); c.Name = "Driver " + idx;
                    int rank = c.Me ? 0 : ++other;
                    for (int n = 1; n <= maxLap; n++)
                    {
                        RfLap l = new RfLap(); l.N = n;
                        double off = c.Me ? 3 * (pos[n] - 1) + (n <= maxLap / 2 ? 0.5 : 2.5) : 3 * rank;
                        l.E = 1000 + 100 * n + off;
                        double offPrev = n == 1 ? off : (c.Me ? 3 * (pos[n - 1] - 1) + (n - 1 <= maxLap / 2 ? 0.5 : 2.5) : 3 * rank);
                        l.S = 1000 + 100 * (n - 1) + offPrev;
                        int p = 1; if (c.Me) p = pos[n]; else p = rank < pos[n] ? rank : rank + 1;
                        l.Pos = p; l.CPos = p; c.Laps.Add(l);
                    }
                    d.Cars.Add(c);
                }
                File.WriteAllText(Path.Combine(Path.Combine(Vault.Root, "field"), d.Id + ".json"), d.ToJson(true, null, false), new UTF8Encoding(false));
                string j13 = Review.BuildNow(f13);
                Dictionary<string, object> r13 = Obj(j13), s13 = G(r13, "session") as Dictionary<string, object>, race = G(r13, "race") as Dictionary<string, object>;
                Ok("3. the review is about the race session", S(G(s13, "type")) == "Race" && I(G(s13, "sessionNum")) == sn, S(G(s13, "type")) + " " + S(G(s13, "sessionNum")));
                Ok("3. race is filled", race != null, Short(j13));
                Ok("3. the result: P4 of 19 from P7", I(G(G(s13, "result"), "finish")) == 4 && I(G(G(s13, "result"), "field")) == 19 && I(G(G(s13, "result"), "start")) == 7, Short(new JavaScriptSerializer().Serialize(G(s13, "result"))));
                object[] ps = A(G(race, "positions"));
                Ok("3. positions by lap: one per lap, ending P4", ps.Length == maxLap && I(ps[ps.Length - 1]) == 4, new JavaScriptSerializer().Serialize(ps));
                Ok("3. pace against the field: his median, the field's, 19 cars", !double.IsNaN(D(G(G(race, "pace"), "mine"))) && !double.IsNaN(D(G(G(race, "pace"), "field"))) && I(G(G(race, "pace"), "cars")) == 19, new JavaScriptSerializer().Serialize(G(race, "pace")));
                Ok("3. at most three costliest corners", A(G(race, "corners")).Length <= 3);
                object air = G(race, "cleanAir");
                Ok("3. at most one clean-air card, marked as one", air == null || (G(air, "cleanAir") is bool && (bool)G(air, "cleanAir") && S(G(air, "sample")).StartsWith("clean-air lap")), Short(new JavaScriptSerializer().Serialize(air)));
                if (air != null) Ok("3. the clean-air card lints clean", Review.Lint(S(G(G(air, "corner"), "label")) + ": " + S(G(air, "happened"))) == null);
                Cards("3", r13, I(G(s13, "clean")) >= 3);
                Console.WriteLine("info 13nov clean " + S(G(s13, "clean")) + " best " + new JavaScriptSerializer().Serialize(G(s13, "best")) + " cleanAir " + (air == null ? "none" : S(G(air, "sample"))));
            }

            // ---------------------------------------------------------------- 2. few laps and no full lap
            Console.WriteLine("section 2. a 2-lap session, a session with no full lap");
            string j2 = Review.BuildNow(cut2);
            Dictionary<string, object> r2 = Obj(j2), s2 = G(r2, "session") as Dictionary<string, object>;
            Ok("2. the 2-lap cut: 2 clean laps", I(G(s2, "clean")) == 2, Short(j2));
            Ok("2. one card, no advice, no plan", A(G(r2, "cards")).Length == 1 && S(G(r2, "plan")) == "", Short(j2));
            Cards("2", r2, false);
            Ok("2. the note says it", S(G(r2, "note")) == "Only 2 clean laps: the costliest corner, no advice", S(G(r2, "note")));
            string j0 = Review.BuildNow(cut0);
            Dictionary<string, object> r0 = Obj(j0);
            Ok("2. no full lap: note \"No full lap yet\", laps and cards empty", S(G(r0, "note")) == "No full lap yet" && A(G(r0, "laps")).Length == 0 && A(G(r0, "cards")).Length == 0, Short(j0));

            // ---------------------------------------------------------------- 5. the corner table, progress, the "ever" reference
            Console.WriteLine("section 5. the corner table, progress, ref ever");
            int code; string cj = Route("/api/review/corners", "id=" + Uri.EscapeDataString(Path.GetFileName(f12)), out code);
            Dictionary<string, object> ct = Obj(cj);
            object[] rows = A(G(G(ct, "lap"), "rows")), rrows = A(G(G(ct, "ref"), "rows"));
            bool fields = rows.Length > 0;
            foreach (object r in rows) foreach (string k in new string[] { "n", "label", "detected", "brakeM", "minSpeed", "pickupM", "time" }) if (!(r as Dictionary<string, object>).ContainsKey(k)) fields = false;
            Ok("5. the corner table: lap 9's rows with n, label, detected, brakeM, minSpeed, pickupM, time", code == 200 && I(G(G(ct, "lap"), "n")) == 9 && fields, Short(cj));
            Ok("5. and the reference's rows", rrows.Length == rows.Length);
            { StringBuilder rb = new StringBuilder(); foreach (object r in rows) rb.Append(S(G(r, "label"))).Append("=").Append(S(G(r, "brakeM"))).Append(" "); Console.WriteLine("info lap 9 brake points (m from the line): " + rb); }
            Dictionary<string, object> defs = G(ct, "defs") as Dictionary<string, object>;
            Ok("5. the four definitions, once", defs != null && defs.Count == 4 && S(G(defs, "brakeM")).StartsWith("brake over 10 %"));
            string cj8 = Route("/api/review/corners", "id=" + Uri.EscapeDataString(Path.GetFileName(f12)) + "&lap=8&ref=9", out code);
            Ok("5. lap 8 against lap 9 of the same session", code == 200 && I(G(G(Obj(cj8), "lap"), "n")) == 8 && I(G(G(Obj(cj8), "ref"), "n")) == 9, Short(cj8));
            string labels12 = ""; foreach (object c in cards) { int n = I(G(G(c, "corner"), "n")); foreach (object r in rows) if (I(G(r, "n")) == n && S(G(r, "label")) != S(G(G(c, "corner"), "label"))) labels12 = "card " + n + " label differs"; }
            Ok("5. a corner's n and label are the same on the cards and in the corner table", labels12.Length == 0, labels12);
            string pj = Review.Progress(S(G(ses, "car")), S(G(ses, "track")));
            Dictionary<string, object> pr = Obj(pj);
            object[] dots = A(G(pr, "sessions"));
            bool dotsOk = dots.Length >= 1; foreach (object o in dots) if (double.IsNaN(D(G(o, "best"))) || D(G(o, "avg5")) < D(G(o, "best")) - 1e-6) dotsOk = false;
            bool has12 = false; foreach (object o in dots) if (Math.Abs(D(G(o, "best")) - 93.832) < 0.0005) has12 = true;
            Ok("5. progress for " + S(G(ses, "car")) + " at " + S(G(ses, "track")) + ": a dot per session (best, avg5) from the lap caches, the 12 Nov best among them", dotsOk && has12 && (f13 == null || dots.Length >= 2), Short(pj));
            bool trend = A(G(pr, "corners")).Length > 0;
            foreach (object o in A(G(pr, "corners"))) if (A(G(o, "lost")).Length != A(G(o, "dates")).Length || A(G(o, "lost")).Length == 0) trend = false;
            Ok("5. progress: the corner trend from the reviews (lost and dates, one each per session)", trend, Short(pj));
            Ok("5. progress: an iRating list (each marked estimate)", G(pr, "irating") is object[]);
            if (f13 == null) Skip("5. ref.kind ever: needs the 13 Nov file");
            else
            {
                Dictionary<string, object> rf2 = G(s2, "ref") as Dictionary<string, object>;
                Ok("5. under 3 clean laps the reference is his best here from another session (kind ever) with a conditions line", S(G(rf2, "kind")) == "ever" && S(G(rf2, "conditions")).StartsWith("track ") && S(G(rf2, "file")) == Path.GetFileName(f13), Short(new JavaScriptSerializer().Serialize(rf2)));
                Console.WriteLine("info ever ref " + new JavaScriptSerializer().Serialize(rf2));
            }

            // ---------------------------------------------------------------- 4. working, then ready (the job, the cache, the session)
            Console.WriteLine("section 4. working first, ready after the job; the job waits for the session");
            Review.Dir = Path.Combine(work, "review-jobs");
            on = true;
            string id12 = "id=" + Uri.EscapeDataString(Path.GetFileName(f12));
            string w = Route("/api/review", id12, out code);
            Ok("4. not built yet: 202 working, \"Reading your laps...\"", code == 202 && S(G(Obj(w), "state")) == "working" && S(G(Obj(w), "say")) == Review.WorkingSay, code + " " + w);
            Thread.Sleep(1500);
            string st = Jobs.Status();
            w = Route("/api/review", id12, out code);
            Ok("4. a session is on: the job waits (still queued, still working, no cache)", st.Contains("\"name\":\"review " + Path.GetFileName(f12) + "\",\"whenFree\":true") && code == 202 && !File.Exists(Review.CachePath(f12)), st);
            string lists0 = StateBuilder.ListsJson();
            on = false;
            DateTime until = DateTime.UtcNow.AddSeconds(120);
            while (DateTime.UtcNow < until) { w = Route("/api/review", id12, out code); if (code == 200) break; Thread.Sleep(300); }
            Ok("4. the session is over: the job ran, the review is ready", code == 200 && S(G(Obj(w), "state")) == "ready", code + " " + Short(w));
            Ok("4. the cache file is there, written temp + move (no .tmp left)", File.Exists(Review.CachePath(f12)) && Directory.GetFiles(Review.Dir, "*.tmp").Length == 0);
            Ok("4. the review list was bumped", StateBuilder.ListsJson() != lists0 && StateBuilder.ListsJson().Contains("\"review\":"), lists0 + " -> " + StateBuilder.ListsJson());
            string tr = Route("/api/review/traces", id12 + "&lap=8", out code);
            Ok("4. traces: 202 working first", code == 202, code + " " + Short(tr));
            until = DateTime.UtcNow.AddSeconds(120);
            while (DateTime.UtcNow < until) { tr = Route("/api/review/traces", id12 + "&lap=8", out code); if (code != 202) break; Thread.Sleep(300); }
            Ok("4. traces: then the PWB1 of lap 8 against lap 9 with the corner set in its header", code == 200 && tr.StartsWith("BIN:PWB1") && tr.Contains("\"corners\":[{") && tr.Contains("\"ref\":{"), code + " " + Short(tr));
            // "last" with laps the store has not worked out: pending, a job, nothing read on the request (the job is left waiting: a session is on)
            on = true; Thread.Sleep(100);
            bool pending; string last = Review.Last(out pending);
            Console.WriteLine("info last " + (last ?? "null") + " pending " + pending);
            string lw = Route("/api/review", "id=last", out code);
            Ok("4. id=last: answers at once (202 working while the lap store works out the newest file, or 200 from the cache)", code == 202 || code == 200, code + " " + Short(lw));

            // ---------------------------------------------------------------- 6. the never-say list
            Console.WriteLine("section 6. Lint");
            string[] never = {
                "T5: You lost 12 % of your speed",
                "T5: That was a mistake under braking 14 m early",
                "T3: An error on the way in cost 0.3 s",
                "T2: Bad exit, 4 mph slower",
                "T7: You should brake 10 m later",
                "T1: You braked 14 m earlier than your best lap and then again later in the corner",
                "You braked 14 m earlier than your best lap",
                "T5: You braked earlier than your best lap",
                "T4: Your exit was 20 percent slower",
                "T6: A terrible entry, 5 mph down" };
            int caught = 0; foreach (string n in never) { string r = Review.Lint(n); if (r != null) caught++; else Console.WriteLine("info not caught: " + n); }
            Ok("6. Lint catches all 10 never-say sentences", caught == 10, caught + " of 10");
            Ok("6. Lint passes a good card line", Review.Lint("T5: You braked 14 m earlier than your best lap") == null);
            Ok("6. LintLine passes \"Brake at the 100 m board\" and the plan shape", Review.LintLine("Brake at the 100 m board") == null && Review.Lint("Next time: Turn 5, brake at the 100 m board, check the entry speed") == null);
            Console.WriteLine("DONE");
            return 0;
        }
    }
}
