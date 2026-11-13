// Pending saves (W0-3 review #2): a save that waits for the session to end must write the LATEST value when it finally runs, not the
// one it was queued with (Jobs keeps one job per name, so a second personal best in the same session used to be dropped and the
// slower first lap reached the disk). And a save never replaces a faster reference already on disk (the reference build that runs
// first after the session may have written a better one). Pure: tests\jobs-test.ps1 checks it.
using System;
using System.Collections.Generic;

namespace IRDash
{
    sealed class PendingSlot<T> where T : class
    {
        readonly Dictionary<string, T> slot = new Dictionary<string, T>();
        readonly Func<T, T, bool> better;       // better(a, b): a should replace b
        public PendingSlot(Func<T, T, bool> better) { this.better = better; }

        public void Put(string key, T value)
        {
            lock (slot) { T have; if (!slot.TryGetValue(key, out have) || better(value, have)) slot[key] = value; }
        }
        public T Take(string key)
        {
            lock (slot) { T v; if (!slot.TryGetValue(key, out v)) return null; slot.Remove(key); return v; }
        }
        public int Count { get { lock (slot) return slot.Count; } }
    }

    static class SaveRule
    {
        // a lap time may be written over the one on disk only when it is not slower (0 = nothing on disk)
        public static bool ShouldWrite(double newTime, double diskTime) { return newTime > 0 && (diskTime <= 0 || newTime <= diskTime + 0.0005); }
    }
}
