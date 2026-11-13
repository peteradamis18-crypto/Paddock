// Prints the gallery order for the folder given on the command line (one file name per line). Used by photo-order-test.ps1.
using System;
using System.Collections.Generic;
using System.IO;
using IRDash;
static class P
{
    static void Main(string[] a)
    {
        string dir = a[0], mine = Path.Combine(dir, "mine");
        List<string> files = new List<string>();
        foreach (string f in Directory.GetFiles(dir)) if (f.EndsWith(".jpg")) files.Add(f);
        if (Directory.Exists(mine)) files.AddRange(Directory.GetFiles(mine));
        foreach (string f in GalOrder.Order(files, mine)) Console.WriteLine(Path.GetFileName(f));
    }
}
