// Side-screen gallery order (W0-10): the same order every time, the newest set of pictures first.
// A "set" is one batch of pictures. Batches are named by their file prefix: no prefix = the first batch (set 0),
// "r2-" = set 2, "r3-" = set 3 ...; pictures in the "mine" folder are Peter's own and count as the newest set.
// Why: the old code sorted every file by name (so "07-..." came before "r2-...") and then shuffled each round, so
// the pictures never came up in any order Peter could recognise.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace IRDash
{
    static class GalOrder
    {
        public static int SetOf(string path, string mineDir)
        {
            if (!string.IsNullOrEmpty(mineDir) && string.Equals(Path.GetDirectoryName(path), mineDir, StringComparison.OrdinalIgnoreCase)) return 100000;
            Match m = Regex.Match(Path.GetFileName(path) ?? "", @"^r(\d{1,4})-", RegexOptions.IgnoreCase);
            return m.Success ? int.Parse(m.Groups[1].Value) : 0;
        }

        // newest set first, then by file name inside a set (so two calls with the same files give the same list)
        public static List<string> Order(IEnumerable<string> files, string mineDir)
        {
            List<string> list = new List<string>(files);
            list.Sort(delegate (string a, string b)
            {
                int c = SetOf(b, mineDir).CompareTo(SetOf(a, mineDir));
                return c != 0 ? c : string.Compare(Path.GetFileName(a), Path.GetFileName(b), StringComparison.OrdinalIgnoreCase);
            });
            return list;
        }
    }
}
