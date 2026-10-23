// Unit check for dash\src\keymsg.cs (compiled together with it by tests\keymsg-test.ps1; Json.Str below is a copy of irdash's).
using System;
using System.Text;
using System.Web.Script.Serialization;
using System.Collections.Generic;

namespace IRDash
{
    static class Json
    {
        public static string Str(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 16);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }
    }

    static class UnitMain
    {
        static int bad = 0;
        static void Check(string what, bool ok) { Console.WriteLine((ok ? "ok    " : "FAIL  ") + what); if (!ok) bad++; }
        static Dictionary<string, object> Cur() { return (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(KeyMsg.Current()); }

        static int Main()
        {
            var d = Cur();
            Check("before any message: seq 0, empty text, ageMs 0", Convert.ToInt64(d["seq"]) == 0 && (string)d["text"] == "" && Convert.ToInt64(d["ageMs"]) == 0);

            string kept = KeyMsg.Set("get-out", "Waiting for the car to stop", "wait");
            d = Cur();
            Check("a message is kept as sent", kept == "Waiting for the car to stop" && (string)d["text"] == kept && (string)d["kind"] == "wait" && (string)d["key"] == "get-out");
            Check("seq counts up from 1", Convert.ToInt64(d["seq"]) == 1);
            Check("at is a unix time in ms and ageMs is small", Convert.ToInt64(d["at"]) > 1700000000000L && Convert.ToInt64(d["ageMs"]) >= 0 && Convert.ToInt64(d["ageMs"]) < 2000);

            KeyMsg.Set("x", "a\r\nb\tc<script>d</script>   e", "ok");
            d = Cur();
            Check("control characters and angle brackets are removed, spaces folded", (string)d["text"] == "a b c script d /script e");
            Check("seq 2 after the second message", Convert.ToInt64(d["seq"]) == 2);

            KeyMsg.Set("x", new string('w', 200), "ok");
            d = Cur();
            Check("text is cut to 80 characters", ((string)d["text"]).Length == 80);

            KeyMsg.Set("x", "hello", "BOGUS");
            Check("an unknown kind becomes ok", (string)Cur()["kind"] == "ok");
            KeyMsg.Set("x", "hello", "NO");
            Check("kind is case-insensitive (no)", (string)Cur()["kind"] == "no");
            KeyMsg.Set("x", "hello", "wait");
            Check("kind wait is kept", (string)Cur()["kind"] == "wait");

            KeyMsg.Set("Bad Key!\"", "hello", "ok");
            Check("a key that is not letters, digits, - or _ is dropped", (string)Cur()["key"] == "");
            KeyMsg.Set(new string('k', 41), "hello", "ok");
            Check("a key over 40 characters is dropped", (string)Cur()["key"] == "");

            long before = Convert.ToInt64(Cur()["seq"]);
            string none1 = KeyMsg.Set("x", "", "ok"), none2 = KeyMsg.Set("x", " \t\r\n <> ", "ok");
            Check("empty or blank text is refused and changes nothing", none1 == "" && none2 == "" && Convert.ToInt64(Cur()["seq"]) == before);

            string acc = "caf" + ((char)233).ToString();
            KeyMsg.Set("x", "Quote \" and backslash \\ and " + acc, "ok");
            d = Cur();
            Check("quotes, backslashes and accents survive as valid JSON", (string)d["text"] == "Quote \" and backslash \\ and " + acc);

            Console.WriteLine(bad == 0 ? "UNIT-DONE" : "UNIT-FAILED");
            return bad == 0 ? 0 : 1;
        }
    }
}
